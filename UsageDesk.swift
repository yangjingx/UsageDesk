import AppKit
import Combine
import Darwin
import SwiftUI

private let dashboardURL = URL(string: "https://chatgpt.com/codex/settings/usage")!

private func dataFolder() -> URL {
    if let override = ProcessInfo.processInfo.environment["USAGEDESK_DATA_DIR"], !override.isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    #if USAGEDESK_TEST
    return URL(fileURLWithPath: "/private/tmp/UsageDeskPreviewData", isDirectory: true)
    #elseif USAGEDESK_PREVIEW
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("UsageDeskPreview", isDirectory: true)
    #else
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("UsageDesk", isDirectory: true)
    #endif
}

struct UsageSnapshot: Codable, Sendable {
    var fiveUsed: Double?
    var weekUsed: Double?
    var fiveReset: Date?
    var weekReset: Date?
    var primaryDurationMins: Int?
    var secondaryDurationMins: Int?
    var updatedAt: Date?
    var source: String?

    static let empty = UsageSnapshot(fiveUsed: nil, weekUsed: nil, fiveReset: nil, weekReset: nil,
                                     primaryDurationMins: nil, secondaryDurationMins: nil,
                                     updatedAt: nil, source: nil)
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshot: UsageSnapshot
    @Published var isRefreshing = false
    @Published var lastError: String?
    private let fileURL: URL

    init() {
        let folder = dataFolder()
        fileURL = folder.appendingPathComponent("usage.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(UsageSnapshot.self, from: data) {
            snapshot = saved
        } else {
            snapshot = .empty
        }
    }

    func reload() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode(UsageSnapshot.self, from: data) else { return }
        if saved.updatedAt != snapshot.updatedAt { snapshot = saved }
    }

    func save(_ value: UsageSnapshot) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            snapshot = value
            lastError = nil
        } catch {
            NSSound.beep()
        }
    }
}

enum FetchResult: Sendable {
    case success(UsageSnapshot)
    case failure(String)
}

enum UsageFetcher {
    private static func codexURL() -> URL? {
        #if USAGEDESK_TEST
        if let path = ProcessInfo.processInfo.environment["USAGEDESK_TEST_CODEX"]
            ?? (Bundle.main.object(forInfoDictionaryKey: "UsageDeskTestCodexPath") as? String) {
            return URL(fileURLWithPath: path)
        }
        #endif
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { "\($0)/codex" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private static func window(_ raw: Any?) -> (Double?, Date?, Int?) {
        guard let info = raw as? [String: Any] else { return (nil, nil, nil) }
        let used = (info["usedPercent"] as? NSNumber)?.doubleValue
        let seconds = (info["resetsAt"] as? NSNumber)?.doubleValue
        let minutes = (info["windowDurationMins"] as? NSNumber)?.intValue
        return (used, seconds.map { Date(timeIntervalSince1970: $0) }, minutes)
    }

    private static func parse(_ data: Data) -> FetchResult? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["id"] as? NSNumber)?.intValue == 2 else { return nil }
        if let error = object["error"] as? [String: Any] {
            return .failure((error["message"] as? String) ?? "Codex 返回了错误")
        }
        guard let result = object["result"] as? [String: Any] else {
            return .failure("没有读取到 Codex 用量")
        }
        let byId = result["rateLimitsByLimitId"] as? [String: Any]
        guard let limits = (byId?["codex"] as? [String: Any])
                ?? (result["rateLimits"] as? [String: Any]) else {
            if byId != nil || result["rateLimits"] != nil {
                return .success(UsageSnapshot(fiveUsed: nil, weekUsed: nil,
                                              fiveReset: nil, weekReset: nil,
                                              primaryDurationMins: nil, secondaryDurationMins: nil,
                                              updatedAt: Date(), source: "当前账户无额度窗口"))
            }
            return .failure("没有读取到 Codex 用量")
        }
        let five = window(limits["primary"])
        let week = window(limits["secondary"])
        return .success(UsageSnapshot(fiveUsed: five.0, weekUsed: week.0,
                                      fiveReset: five.1, weekReset: week.1,
                                      primaryDurationMins: five.2, secondaryDurationMins: week.2,
                                      updatedAt: Date(), source: "自动同步"))
    }

    static func fetch() -> FetchResult {
        guard let executable = codexURL() else { return .failure("未找到 Codex 命令行程序") }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { return .failure("无法启动本机 Codex") }
        defer {
            if process.isRunning { process.terminate() }
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }

        let messages: [[String: Any]] = [
            ["jsonrpc": "2.0", "method": "initialize", "id": 1,
             "params": ["clientInfo": ["name": "UsageDesk", "title": "UsageDesk", "version": "1.1"]]],
            ["jsonrpc": "2.0", "method": "initialized", "params": [:]],
            ["jsonrpc": "2.0", "method": "account/rateLimits/read", "id": 2, "params": [:]]
        ]
        for message in messages {
            guard let data = try? JSONSerialization.data(withJSONObject: message) else { continue }
            input.fileHandleForWriting.write(data + Data([10]))
        }

        let descriptor = output.fileHandleForReading.fileDescriptor
        let deadline = Date().addingTimeInterval(15)
        var buffer = Data()
        while Date() < deadline {
            var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let milliseconds = max(1, Int32(deadline.timeIntervalSinceNow * 1000))
            let ready = Darwin.poll(&item, 1, milliseconds)
            if ready == 0 { break }
            if ready < 0 { continue }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            buffer.append(contentsOf: chunk.prefix(count))
            if buffer.count > 2_000_000 { return .failure("Codex 响应过大") }
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if let result = parse(line) { return result }
            }
        }
        return .failure("Codex 用量请求超时")
    }
}

private func percentText(_ value: Double?) -> String {
    guard let value else { return "—" }
    return "\(Int(value.rounded()))%"
}

private func localized(_ language: AppLanguage, _ chinese: String, _ english: String) -> String {
    language == .chinese ? chinese : english
}

private func windowTitle(_ minutes: Int?, fallback: String, language: AppLanguage) -> String {
    guard let minutes, minutes > 0 else { return fallback }
    if minutes == 10_080 { return localized(language, "每周", "Weekly") }
    if minutes % 10_080 == 0 { return localized(language, "\(minutes / 10_080) 周", "\(minutes / 10_080) weeks") }
    if minutes % 1_440 == 0 { return localized(language, "\(minutes / 1_440) 天", "\(minutes / 1_440) days") }
    if minutes % 60 == 0 { return localized(language, "\(minutes / 60) 小时", "\(minutes / 60) hours") }
    return localized(language, "\(minutes) 分钟", "\(minutes) minutes")
}

private func resetText(_ date: Date?, language: AppLanguage) -> String {
    guard let date else { return localized(language, "重置时间未填", "Reset time unknown") }
    let format = DateFormatter()
    format.locale = Locale(identifier: language == .chinese ? "zh_CN" : "en_US")
    format.dateFormat = language == .chinese ? "M月d日 HH:mm" : "MMM d, HH:mm"
    return localized(language, "\(format.string(from: date)) 重置", "Resets \(format.string(from: date))")
}

private func updatedText(_ date: Date?, language: AppLanguage) -> String {
    guard let date else { return localized(language, "尚未录入", "No data yet") }
    let format = DateFormatter()
    format.locale = Locale(identifier: language == .chinese ? "zh_CN" : "en_US")
    format.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm:ss" :
        (language == .chinese ? "M月d日 HH:mm:ss" : "MMM d, HH:mm:ss")
    return localized(language, "\(format.string(from: date)) 更新", "Updated \(format.string(from: date))")
}

struct MeterRow: View {
    let title: String
    let symbol: String
    let used: Double?
    let reset: Date?
    let tint: Color
    let language: AppLanguage

    private var remaining: Double? { used.map { max(0, 100 - $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(localized(language, "剩余", "Left"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                    Text(percentText(remaining))
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14))
                    Capsule().fill(tint)
                        .frame(width: proxy.size.width * CGFloat(min(max(remaining ?? 0, 0), 100) / 100))
                }
            }
            .frame(height: 8)
            HStack {
                Text(used == nil ? localized(language, "等待用量数据", "Waiting for usage") :
                     localized(language, "已用 \(percentText(used))", "Used \(percentText(used))"))
                Spacer()
                Text(resetText(reset, language: language))
            }
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.65))
        }
    }
}

struct WidgetCard: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var preferences: AppPreferences
    let onRefresh: () -> Void
    @State private var showEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack(spacing: 10) {
                BrandLogo(name: "codex-mark", fallback: "chart.bar.fill")
                VStack(alignment: .leading, spacing: 2) {
                    ProviderTitle(provider: .codex, preferences: preferences)
                    Text(updatedText(store.snapshot.updatedAt, language: preferences.language))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.57))
                }
                Spacer()
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .frame(width: 27, height: 30)
                .background(InteractiveRegion(id: "codex.refresh"))
                .foregroundStyle(.white.opacity(0.8))
                .disabled(store.isRefreshing)
                .help(localized(preferences.language, "立即刷新用量", "Refresh usage now"))
                Button { showEditor = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .frame(width: 27, height: 30)
                .background(InteractiveRegion(id: "codex.edit"))
                .foregroundStyle(.white.opacity(0.8))
                .help(localized(preferences.language, "Codex 设置与手动更新", "Codex settings and manual update"))
            }

            if let used = store.snapshot.fiveUsed {
                MeterRow(title: windowTitle(store.snapshot.primaryDurationMins,
                                            fallback: localized(preferences.language, "主要额度", "Primary limit"),
                                            language: preferences.language),
                         symbol: "clock", used: used, reset: store.snapshot.fiveReset,
                         tint: Color(red: 0.41, green: 0.91, blue: 0.77), language: preferences.language)
            }
            if let used = store.snapshot.weekUsed {
                MeterRow(title: windowTitle(store.snapshot.secondaryDurationMins,
                                            fallback: localized(preferences.language, "附加额度", "Secondary limit"),
                                            language: preferences.language),
                         symbol: "clock", used: used, reset: store.snapshot.weekReset,
                         tint: Color(red: 0.59, green: 0.70, blue: 1.0), language: preferences.language)
            }
            if store.snapshot.fiveUsed == nil && store.snapshot.weekUsed == nil {
                Text(store.isRefreshing ?
                     localized(preferences.language, "正在读取本机额度…", "Reading local limits…") :
                     localized(preferences.language, "当前账户没有可显示的用量窗口", "No usage windows for this account"))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, minHeight: 95)
            }

            HStack {
                Text(store.isRefreshing ? localized(preferences.language, "正在同步…", "Syncing…") :
                     (store.lastError == nil ?
                      (store.snapshot.source == "手动更新" ? localized(preferences.language, "手动更新", "Manual update") :
                       store.snapshot.source == "快捷指令更新" ? localized(preferences.language, "快捷指令更新", "Shortcut update") :
                       localized(preferences.language, "自动同步", "Auto sync")) :
                      localized(preferences.language, "同步失败 · 显示上次数据", "Sync failed · showing last data")))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.44))
                Spacer()
                Button(localized(preferences.language, "打开官方面板 ↗", "Open dashboard ↗")) {
                    NSWorkspace.shared.open(dashboardURL)
                }
                    .buttonStyle(.plain)
                    .background(InteractiveRegion(id: "codex.dashboard"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(red: 0.61, green: 0.93, blue: 0.84))
            }
        }
        .padding(21)
        .frame(width: 330, height: 268)
        .background {
            RoundedRectangle(cornerRadius: 23)
                .fill(LinearGradient(colors: [Color(red: 0.11, green: 0.16, blue: 0.22),
                                              Color(red: 0.07, green: 0.09, blue: 0.15)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: 23).stroke(.white.opacity(0.15), lineWidth: 1)
                }
        }
        .sheet(isPresented: $showEditor) { UsageEditor(store: store, preferences: preferences) }
    }
}

struct UsageEditor: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var preferences: AppPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var five: Double
    @State private var week: Double
    @State private var fiveReset: Date
    @State private var weekReset: Date
    @State private var showPrimary: Bool
    @State private var showSecondary: Bool
    @State private var hasFiveReset: Bool
    @State private var hasWeekReset: Bool

    init(store: UsageStore, preferences: AppPreferences) {
        self.store = store
        self.preferences = preferences
        let value = store.snapshot
        _five = State(initialValue: value.fiveUsed ?? 0)
        _week = State(initialValue: value.weekUsed ?? 0)
        _fiveReset = State(initialValue: value.fiveReset ?? Date().addingTimeInterval(5 * 3600))
        _weekReset = State(initialValue: value.weekReset ?? Date().addingTimeInterval(7 * 86400))
        _showPrimary = State(initialValue: value.fiveUsed != nil)
        _showSecondary = State(initialValue: value.weekUsed != nil)
        _hasFiveReset = State(initialValue: value.fiveReset != nil)
        _hasWeekReset = State(initialValue: value.weekReset != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(localized(preferences.language, "更新用量", "Edit usage"))
                .font(.title3.bold())
            Text(localized(preferences.language, "填入官方用量面板显示的已用百分比。",
                           "Enter the used percentages shown on the official dashboard."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(windowTitle(store.snapshot.primaryDurationMins,
                               fallback: localized(preferences.language, "主要额度", "Primary limit"),
                               language: preferences.language), isOn: $showPrimary)
            if showPrimary {
                HStack {
                    Text(localized(preferences.language, "已用", "Used"))
                    Spacer()
                    TextField("0–100", value: $five, format: .number.precision(.fractionLength(0)))
                        .frame(width: 65)
                        .multilineTextAlignment(.trailing)
                    Text("%")
                }
                Toggle(localized(preferences.language, "设置重置时间", "Set reset time"), isOn: $hasFiveReset)
                if hasFiveReset {
                    DatePicker("", selection: $fiveReset, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                }
            }
            Toggle(windowTitle(store.snapshot.secondaryDurationMins,
                               fallback: localized(preferences.language, "附加额度", "Secondary limit"),
                               language: preferences.language), isOn: $showSecondary)
            if showSecondary {
                HStack {
                    Text(localized(preferences.language, "已用", "Used"))
                    Spacer()
                    TextField("0–100", value: $week, format: .number.precision(.fractionLength(0)))
                        .frame(width: 65)
                        .multilineTextAlignment(.trailing)
                    Text("%")
                }
                Toggle(localized(preferences.language, "设置重置时间", "Set reset time"), isOn: $hasWeekReset)
                if hasWeekReset {
                    DatePicker("", selection: $weekReset, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                }
            }
            HStack {
                Spacer()
                Button(localized(preferences.language, "取消", "Cancel")) { dismiss() }
                Button(localized(preferences.language, "保存", "Save")) {
                    store.save(UsageSnapshot(fiveUsed: showPrimary ? five : nil,
                                             weekUsed: showSecondary ? week : nil,
                                             fiveReset: showPrimary && hasFiveReset ? fiveReset : nil,
                                             weekReset: showSecondary && hasWeekReset ? weekReset : nil,
                                             primaryDurationMins: showPrimary ? store.snapshot.primaryDurationMins : nil,
                                             secondaryDurationMins: showSecondary ? store.snapshot.secondaryDurationMins : nil,
                                             updatedAt: Date(), source: "手动更新"))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled((showPrimary && !(0...100).contains(five)) ||
                          (showSecondary && !(0...100).contains(week)))
            }
        }
        .padding(22)
        .frame(width: 350)
    }
}

private func money(_ value: Decimal, currency: String) -> String {
    let number = NSDecimalNumber(decimal: value)
    let format = NumberFormatter()
    format.numberStyle = .currency
    format.currencyCode = currency
    format.maximumFractionDigits = 2
    format.minimumFractionDigits = 2
    return format.string(from: number) ?? "\(currency) \(number)"
}

struct BrandLogo: View {
    let name: String
    let fallback: String

    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: name, withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(4)
            } else {
                Image(systemName: fallback)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 34, height: 34)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityLabel(name == "codex-mark" ? "Codex" : "DeepSeek")
    }
}

struct ProviderTitle: View {
    let provider: ProviderID
    @ObservedObject var preferences: AppPreferences
    @State private var showChooser = false

    private var title: String {
        provider == .codex ? localized(preferences.language, "Codex 用量", "Codex usage") : "DeepSeek API"
    }

    var body: some View {
        if preferences.layout == .switchCards {
            Button { showChooser = true } label: {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .foregroundStyle(.white)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(InteractiveRegion(id: "provider.title.\(provider.rawValue)"))
            .help(localized(preferences.language, "点击选择卡片", "Choose a card"))
            .popover(isPresented: $showChooser, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(ProviderID.allCases, id: \.self) { choice in
                        Button {
                            preferences.selectedProvider = choice
                            showChooser = false
                        } label: {
                            HStack {
                                Text(choice == .codex ? "Codex" : "DeepSeek")
                                Spacer()
                                if preferences.selectedProvider == choice {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .frame(width: 130)
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                    }
                }
                .padding(5)
                .background(Color(red: 0.12, green: 0.16, blue: 0.25), in: RoundedRectangle(cornerRadius: 12))
            }
        } else {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

struct DeepSeekCard: View {
    @ObservedObject var store: DeepSeekStore
    @ObservedObject var preferences: AppPreferences
    let onRefresh: () -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                BrandLogo(name: "deepseek-mark", fallback: "water.waves")
                VStack(alignment: .leading, spacing: 2) {
                    ProviderTitle(provider: .deepSeek, preferences: preferences)
                    Text(updatedText(store.snapshot?.updatedAt, language: preferences.language))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.57))
                }
                Spacer()
                Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .frame(width: 27, height: 30)
                    .background(InteractiveRegion(id: "deepseek.refresh"))
                    .disabled(!store.hasCredential || store.isRefreshing)
                    .help(localized(preferences.language, "刷新余额", "Refresh balance"))
                Button(action: onSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(.plain)
                    .frame(width: 27, height: 30)
                    .background(InteractiveRegion(id: "deepseek.settings"))
                    .help(localized(preferences.language, "DeepSeek 设置", "DeepSeek settings"))
            }

            if !store.hasCredential {
                Spacer(minLength: 10)
                Button(localized(preferences.language, "连接 DeepSeek API", "Connect DeepSeek API"), action: onSettings)
                    .buttonStyle(.borderedProminent)
                    .background(InteractiveRegion(id: "deepseek.connect"))
                Text(localized(preferences.language, "输入你自己的 API Key 后显示账户余额。",
                               "Enter your own API key to see your account balance."))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                Spacer(minLength: 10)
            } else if let snapshot = store.snapshot {
                ForEach(snapshot.balances, id: \.currency) { balance in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(localized(preferences.language, "可用余额", "Available balance"))
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.65))
                            Spacer()
                            Text(money(balance.total, currency: balance.currency))
                                .font(.system(size: 23, weight: .bold, design: .rounded))
                                .monospacedDigit()
                        }
                        Text(localized(preferences.language,
                                       "赠金 \(money(balance.granted, currency: balance.currency)) · 充值 \(money(balance.toppedUp, currency: balance.currency))",
                                       "Granted \(money(balance.granted, currency: balance.currency)) · Paid \(money(balance.toppedUp, currency: balance.currency))"))
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                if snapshot.balances.isEmpty {
                    Text(localized(preferences.language, "账户没有返回余额条目", "No balance entries returned"))
                        .font(.system(size: 12))
                }
                Spacer(minLength: 0)
                Text(snapshot.isAvailable ? localized(preferences.language, "可用于 API 调用", "Available for API calls") :
                     localized(preferences.language, "余额不可用于 API 调用", "Unavailable for API calls"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(snapshot.isAvailable ? Color(red: 0.61, green: 0.93, blue: 0.84) : .orange)
            } else {
                Spacer(minLength: 10)
                Text(store.isRefreshing ? localized(preferences.language, "正在读取余额…", "Reading balance…") :
                     localized(preferences.language, "等待余额数据", "Waiting for balance data"))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 10)
            }

            HStack {
                Text(store.lastError == nil ?
                     (store.isRefreshing ? localized(preferences.language, "正在同步…", "Syncing…") :
                      localized(preferences.language, "API 余额", "API balance")) :
                     localized(preferences.language, "同步失败 · 显示上次数据", "Sync failed · showing last data"))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Button(localized(preferences.language, "打开 DeepSeek ↗", "Open DeepSeek ↗")) {
                    NSWorkspace.shared.open(URL(string: "https://platform.deepseek.com")!)
                }
                .buttonStyle(.plain)
                .background(InteractiveRegion(id: "deepseek.dashboard"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color(red: 0.68, green: 0.80, blue: 1))
            }
        }
        .foregroundStyle(.white)
        .padding(21)
        .frame(width: 330, height: 268)
        .background {
            RoundedRectangle(cornerRadius: 23)
                .fill(LinearGradient(colors: [Color(red: 0.11, green: 0.15, blue: 0.25),
                                              Color(red: 0.07, green: 0.09, blue: 0.16)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay { RoundedRectangle(cornerRadius: 23).stroke(.white.opacity(0.15), lineWidth: 1) }
        }
    }
}

struct UsageDeskSettings: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var deepSeek: DeepSeekStore
    let onCredentialChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("deepSeekRefreshInterval") private var deepSeekInterval = 60.0
    @State private var enteredKey = ""
    @State private var feedback = ""
    @State private var testing = false
    @State private var credentialBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text(localized(preferences.language, "DeepSeek API 设置", "DeepSeek API settings"))
                .font(.title3.bold())
            Text(deepSeek.hasCredential ?
                 localized(preferences.language, "已保存 API Key；输入新密钥可以替换。", "API key saved. Enter a new key to replace it.") :
                 localized(preferences.language, "输入你的 DeepSeek 开放平台 API Key。", "Enter your DeepSeek Open Platform API key."))
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("API Key", text: $enteredKey)
                .textFieldStyle(.roundedBorder)
            Picker(localized(preferences.language, "余额刷新间隔", "Balance refresh interval"),
                   selection: $deepSeekInterval) {
                Text(localized(preferences.language, "30 秒", "30 seconds")).tag(30.0)
                Text(localized(preferences.language, "1 分钟", "1 minute")).tag(60.0)
                Text(localized(preferences.language, "5 分钟", "5 minutes")).tag(300.0)
                Text(localized(preferences.language, "15 分钟", "15 minutes")).tag(900.0)
            }
            HStack {
                Button(localized(preferences.language, "测试连接", "Test connection")) {
                    let typedKey = enteredKey
                    testing = true
                    Task {
                        let key: String? = typedKey.isEmpty
                            ? await Task.detached(priority: .userInitiated) { DeepSeekCredential.read() }.value
                            : typedKey
                        guard let key, !key.isEmpty else {
                            feedback = localized(preferences.language, "没有可用密钥", "No key available")
                            testing = false
                            return
                        }
                        do {
                            _ = try await DeepSeekAPI.fetch(key: key)
                            feedback = localized(preferences.language, "连接成功", "Connection successful")
                        } catch {
                            feedback = localized(preferences.language, "连接失败，请检查密钥或网络", "Connection failed; check the key or network")
                        }
                        testing = false
                    }
                }
                .disabled(testing || credentialBusy || (enteredKey.isEmpty && !deepSeek.hasCredential))
                Button(localized(preferences.language, "保存密钥", "Save key")) {
                    let key = enteredKey
                    credentialBusy = true
                    Task {
                        if await deepSeek.replaceCredential(key) {
                            enteredKey = ""
                            feedback = localized(preferences.language, "已保存到系统钥匙串", "Saved to Keychain")
                            onCredentialChanged()
                        } else {
                            feedback = localized(preferences.language, "保存失败", "Could not save key")
                        }
                        credentialBusy = false
                    }
                }
                .disabled(credentialBusy || enteredKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(localized(preferences.language, "删除密钥", "Remove key")) {
                    credentialBusy = true
                    Task {
                        if await deepSeek.removeCredential() {
                            feedback = localized(preferences.language, "密钥已删除", "Key removed")
                            onCredentialChanged()
                        }
                        credentialBusy = false
                    }
                }
                .disabled(credentialBusy || !deepSeek.hasCredential)
            }
            if !feedback.isEmpty { Text(feedback).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button(localized(preferences.language, "完成", "Done")) { dismiss() }
            }
        }
        .padding(22)
        .frame(width: 430)
    }
}

struct DesktopCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var codex: UsageStore
    @ObservedObject var deepSeek: DeepSeekStore
    @ObservedObject var preferences: AppPreferences
    let onCodexRefresh: () -> Void
    let onDeepSeekRefresh: () -> Void
    let onCredentialChanged: () -> Void

    private var cardAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.22)
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 10) {
                if preferences.layout == .vertical {
                    VStack(spacing: 10) {
                        WidgetCard(store: codex, preferences: preferences, onRefresh: onCodexRefresh)
                        DeepSeekCard(store: deepSeek, preferences: preferences,
                                     onRefresh: onDeepSeekRefresh,
                                     onSettings: { preferences.showSettings = true })
                    }
                    .transition(.opacity)
                } else {
                    ZStack(alignment: .top) {
                        if preferences.selectedProvider == .codex {
                            WidgetCard(store: codex, preferences: preferences,
                                       onRefresh: onCodexRefresh)
                                .transition(.opacity)
                        } else {
                            DeepSeekCard(store: deepSeek, preferences: preferences,
                                         onRefresh: onDeepSeekRefresh,
                                         onSettings: { preferences.showSettings = true })
                                .transition(.opacity)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .frame(width: 330)
            .animation(cardAnimation, value: preferences.layout)
            .animation(cardAnimation, value: preferences.selectedProvider)
        }
        .scrollIndicators(.hidden)
        .frame(width: 330)
        .sheet(isPresented: $preferences.showSettings) {
            UsageDeskSettings(preferences: preferences, deepSeek: deepSeek,
                              onCredentialChanged: onCredentialChanged)
        }
    }
}

final class InteractiveRegionView: NSView {
    var regionID = ""

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        (window as? CardWindow)?.interactiveRegions.removeValue(forKey: regionID)
        super.viewWillMove(toWindow: newWindow)
    }

    override func layout() {
        super.layout()
        publish()
    }

    func publish() {
        guard let window = window as? CardWindow else { return }
        window.interactiveRegions[regionID] = convert(bounds, to: nil).insetBy(dx: -3, dy: -3)
    }
}

struct InteractiveRegion: NSViewRepresentable {
    let id: String
    func makeNSView(context: Context) -> InteractiveRegionView {
        let view = InteractiveRegionView()
        view.regionID = id
        return view
    }
    func updateNSView(_ view: InteractiveRegionView, context: Context) {
        view.regionID = id
        view.publish()
    }
}

final class CardWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { 0.22 }

    var interactiveRegions: [String: NSRect] = [:]
    private var dragAnchor: NSPoint?

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            let point = event.locationInWindow
            if !interactiveRegions.values.contains(where: { $0.contains(point) }) {
                dragAnchor = point
                return
            }
        case .leftMouseDragged:
            if let dragAnchor {
                let point = event.locationInWindow
                setFrameOrigin(NSPoint(x: frame.origin.x + point.x - dragAnchor.x,
                                       y: frame.origin.y + point.y - dragAnchor.y))
                return
            }
        case .leftMouseUp:
            if dragAnchor != nil {
                dragAnchor = nil
                saveFrame(usingName: "UsageDeskWindow")
                return
            }
        default:
            break
        }
        super.sendEvent(event)
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private let deepSeek = DeepSeekStore(folder: dataFolder())
    private let preferences = AppPreferences()
    private var window: CardWindow!
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?
    private var refreshTimer: Timer?
    private var nextRefreshAt = Date.distantPast
    private var nextDeepSeekRefreshAt = Date.distantPast
    private var failureCount = 0
    private var deepSeekFailureCount = 0
    private var pinItem: NSMenuItem!
    private var autoItem: NSMenuItem!
    private var intervalItems: [NSMenuItem] = []
    private var layoutItems: [NSMenuItem] = []
    private var languageItems: [NSMenuItem] = []
    private var menuItems: [String: NSMenuItem] = [:]
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        window = CardWindow(contentRect: NSRect(x: 0, y: 0, width: 330, height: 268),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: DesktopCard(
            codex: store, deepSeek: deepSeek, preferences: preferences,
            onCodexRefresh: { [weak self] in self?.refreshUsage() },
            onDeepSeekRefresh: { [weak self] in self?.refreshDeepSeek() },
            onCredentialChanged: { [weak self] in self?.credentialChanged() }))
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.level = keepOnTop ? .floating : .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.setFrameAutosaveName("UsageDeskWindow")
        if !window.setFrameUsingName("UsageDeskWindow") {
            window.center()
        }
        resizeWindow()
        window.makeKeyAndOrderFront(nil)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "UsageDesk")
        let menu = NSMenu()
        let showItem = NSMenuItem(title: "", action: #selector(toggleWindow), keyEquivalent: "")
        menuItems["show"] = showItem
        menu.addItem(showItem)
        let refreshItem = NSMenuItem(title: "", action: #selector(refreshNow), keyEquivalent: "")
        menuItems["refresh"] = refreshItem
        menu.addItem(refreshItem)
        let settingsItem = NSMenuItem(title: "", action: #selector(showSettings), keyEquivalent: "")
        menuItems["settings"] = settingsItem
        menu.addItem(settingsItem)
        let layoutItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menuItems["layout"] = layoutItem
        let layoutMenu = NSMenu()
        for layout in CardLayout.allCases {
            let item = NSMenuItem(title: "", action: #selector(selectLayout(_:)), keyEquivalent: "")
            item.representedObject = layout.rawValue
            item.target = self
            layoutMenu.addItem(item)
            layoutItems.append(item)
        }
        layoutItem.submenu = layoutMenu
        menu.addItem(layoutItem)
        let languageItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menuItems["language"] = languageItem
        let languageMenu = NSMenu()
        for language in AppLanguage.allCases {
            let item = NSMenuItem(title: "", action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.representedObject = language.rawValue
            item.target = self
            languageMenu.addItem(item)
            languageItems.append(item)
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)
        pinItem = NSMenuItem(title: "始终置顶", action: #selector(togglePin), keyEquivalent: "")
        pinItem.state = keepOnTop ? .on : .off
        menu.addItem(pinItem)
        autoItem = NSMenuItem(title: "自动刷新用量", action: #selector(toggleAutoRefresh), keyEquivalent: "")
        autoItem.state = autoRefresh ? .on : .off
        menu.addItem(autoItem)
        menuItems["auto"] = autoItem
        let intervalItem = NSMenuItem(title: "刷新间隔", action: nil, keyEquivalent: "")
        menuItems["interval"] = intervalItem
        let intervalMenu = NSMenu()
        for (title, seconds) in [("10 秒", 10.0), ("30 秒", 30.0), ("1 分钟", 60.0), ("5 分钟", 300.0)] {
            let item = NSMenuItem(title: title, action: #selector(selectInterval(_:)), keyEquivalent: "")
            item.representedObject = seconds
            item.target = self
            intervalMenu.addItem(item)
            intervalItems.append(item)
        }
        intervalMenu.addItem(NSMenuItem.separator())
        let customItem = NSMenuItem(title: "自定义…", action: #selector(customInterval), keyEquivalent: "")
        customItem.target = self
        intervalMenu.addItem(customItem)
        intervalItems.append(customItem)
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)
        updateIntervalChecks()
        let dashboardItem = NSMenuItem(title: "", action: #selector(openDashboard), keyEquivalent: "")
        menuItems["dashboard"] = dashboardItem
        menu.addItem(dashboardItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "", action: #selector(quit), keyEquivalent: "q")
        menuItems["quit"] = quitItem
        menu.addItem(quitItem)
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
        updateMenuText()
        updateLayoutChecks()
        updateLanguageChecks()

        preferences.$layout.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.resizeWindow(animated: true)
                self?.updateLayoutChecks()
            }
        }.store(in: &subscriptions)
        preferences.$selectedProvider.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizeWindow(animated: true) }
        }.store(in: &subscriptions)
        preferences.$language.dropFirst().sink { [weak self] _ in
            self?.updateMenuText()
            self?.updateIntervalChecks()
            self?.updateLanguageChecks()
        }.store(in: &subscriptions)
        deepSeek.$hasCredential.dropFirst().sink { [weak self] available in
            if available { self?.refreshDeepSeek() }
        }.store(in: &subscriptions)

        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.store.reload() }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.autoRefresh else { return }
                if Date() >= self.nextRefreshAt { self.refreshUsage() }
                if self.deepSeek.hasCredential && Date() >= self.nextDeepSeekRefreshAt {
                    self.refreshDeepSeek()
                }
            }
        }
        if autoRefresh {
            refreshUsage()
            if deepSeek.hasCredential { refreshDeepSeek() }
        }
    }

    private func resizeWindow(animated: Bool = false) {
        guard let window else { return }
        let desiredHeight: CGFloat = preferences.layout == .vertical ? 546 : 268
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        let height = min(desiredHeight, max(260, (visible?.height ?? desiredHeight) - 24))
        var frame = window.frame
        frame.size = NSSize(width: 330, height: height)
        frame.origin.y = window.frame.maxY - height
        if let visible {
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        }
        window.setFrame(frame, display: true,
                        animate: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        window.saveFrame(usingName: "UsageDeskWindow")
    }

    private func updateMenuText() {
        let lang = preferences.language
        menuItems["show"]?.title = localized(lang, "显示 / 隐藏卡片", "Show / hide card")
        menuItems["refresh"]?.title = localized(lang, "立即刷新", "Refresh now")
        menuItems["settings"]?.title = localized(lang, "DeepSeek API 设置…", "DeepSeek API settings…")
        menuItems["layout"]?.title = localized(lang, "卡片布局", "Card layout")
        layoutItems[0].title = localized(lang, "切换卡片", "Switch cards")
        layoutItems[1].title = localized(lang, "垂直展开", "Show both vertically")
        menuItems["language"]?.title = localized(lang, "界面语言", "Language")
        languageItems[0].title = "中文"
        languageItems[1].title = "English"
        pinItem?.title = localized(lang, "始终置顶", "Always on top")
        menuItems["auto"]?.title = localized(lang, "自动刷新", "Auto refresh")
        menuItems["interval"]?.title = localized(lang, "Codex 刷新间隔", "Codex refresh interval")
        menuItems["dashboard"]?.title = localized(lang, "打开 Codex 官方面板", "Open Codex dashboard")
        menuItems["quit"]?.title = localized(lang, "退出", "Quit")
    }

    private var keepOnTop: Bool {
        (UserDefaults.standard.object(forKey: "keepOnTop") as? Bool) ?? true
    }

    private var autoRefresh: Bool {
        (UserDefaults.standard.object(forKey: "autoRefresh") as? Bool) ?? true
    }

    private var refreshInterval: TimeInterval {
        let saved = UserDefaults.standard.double(forKey: "refreshInterval")
        return saved == 0 ? 10 : min(max(saved, 10), 3600)
    }

    private func updateLayoutChecks() {
        for (index, item) in layoutItems.enumerated() {
            item.state = CardLayout.allCases[index] == preferences.layout ? .on : .off
        }
    }

    private func updateLanguageChecks() {
        for (index, item) in languageItems.enumerated() {
            item.state = AppLanguage.allCases[index] == preferences.language ? .on : .off
        }
    }

    @objc private func selectLayout(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let layout = CardLayout(rawValue: raw) else { return }
        preferences.layout = layout
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let language = AppLanguage(rawValue: raw) else { return }
        preferences.language = language
    }

    private func updateIntervalChecks() {
        let presets = [10.0, 30.0, 60.0, 300.0]
        for (index, item) in intervalItems.enumerated() {
            item.state = index < presets.count
                ? (refreshInterval == presets[index] ? .on : .off)
                : (presets.contains(refreshInterval) ? .off : .on)
        }
        intervalItems.last?.title = presets.contains(refreshInterval)
            ? localized(preferences.language, "自定义…", "Custom…") :
              localized(preferences.language, "自定义…（\(Int(refreshInterval)) 秒）",
                        "Custom… (\(Int(refreshInterval)) sec)")
    }

    @objc private func selectInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        UserDefaults.standard.set(seconds, forKey: "refreshInterval")
        nextRefreshAt = Date().addingTimeInterval(seconds)
        updateIntervalChecks()
    }

    @objc private func customInterval() {
        let alert = NSAlert()
        alert.messageText = "自定义刷新间隔"
        alert.informativeText = "请输入 10 到 3600 秒之间的整数。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 190, height: 25))
        field.stringValue = String(Int(refreshInterval))
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let seconds = Int(field.stringValue), (10...3600).contains(seconds) else {
            let error = NSAlert()
            error.messageText = "请输入 10 到 3600 秒的整数"
            error.runModal()
            return
        }
        UserDefaults.standard.set(Double(seconds), forKey: "refreshInterval")
        nextRefreshAt = Date().addingTimeInterval(Double(seconds))
        updateIntervalChecks()
    }

    private func refreshUsage() {
        guard !store.isRefreshing else { return }
        store.isRefreshing = true
        let store = self.store
        Task {
            let result = await Task.detached(priority: .utility) { UsageFetcher.fetch() }.value
            store.isRefreshing = false
            switch result {
            case .success(let value):
                self.failureCount = 0
                self.nextRefreshAt = Date().addingTimeInterval(self.refreshInterval)
                store.save(value)
            case .failure(let message):
                self.failureCount += 1
                let retry = min(300, self.refreshInterval * Double(1 << min(self.failureCount, 5)))
                self.nextRefreshAt = Date().addingTimeInterval(max(self.refreshInterval, retry))
                store.lastError = message
            }
        }
    }

    private var deepSeekRefreshInterval: TimeInterval {
        let saved = UserDefaults.standard.double(forKey: "deepSeekRefreshInterval")
        return saved == 0 ? 60 : min(max(saved, 30), 3600)
    }

    private func refreshDeepSeek() {
        guard deepSeek.hasCredential, !deepSeek.isRefreshing else { return }
        deepSeek.isRefreshing = true
        let deepSeek = self.deepSeek
        Task {
            let storedKey = await Task.detached(priority: .utility) {
                DeepSeekCredential.read()
            }.value
            guard let key = storedKey else {
                deepSeek.hasCredential = false
                deepSeek.isRefreshing = false
                return
            }
            do {
                let value = try await DeepSeekAPI.fetch(key: key)
                let currentKey = await Task.detached(priority: .utility) {
                    DeepSeekCredential.read()
                }.value
                guard currentKey == key else {
                    deepSeek.isRefreshing = false
                    return
                }
                deepSeekFailureCount = 0
                nextDeepSeekRefreshAt = Date().addingTimeInterval(deepSeekRefreshInterval)
                deepSeek.save(value)
            } catch {
                deepSeekFailureCount += 1
                let retry = min(600, deepSeekRefreshInterval * Double(1 << min(deepSeekFailureCount, 5)))
                nextDeepSeekRefreshAt = Date().addingTimeInterval(max(deepSeekRefreshInterval, retry))
                deepSeek.lastError = String(describing: error)
            }
            deepSeek.isRefreshing = false
        }
    }

    private func credentialChanged() {
        nextDeepSeekRefreshAt = .distantPast
        if deepSeek.hasCredential { refreshDeepSeek() }
    }

    @objc private func refreshNow() {
        refreshUsage()
        refreshDeepSeek()
    }

    @objc private func showSettings() {
        preferences.showSettings = true
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func togglePin() {
        let next = !keepOnTop
        UserDefaults.standard.set(next, forKey: "keepOnTop")
        window.level = next ? .floating : .normal
        pinItem.state = next ? .on : .off
    }

    @objc private func toggleAutoRefresh() {
        let next = !autoRefresh
        UserDefaults.standard.set(next, forKey: "autoRefresh")
        autoItem.state = next ? .on : .off
        if next {
            refreshUsage()
            refreshDeepSeek()
        }
    }

    @objc private func toggleWindow() {
        if window.isVisible { window.orderOut(nil) }
        else { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    }

    @objc private func openDashboard() { NSWorkspace.shared.open(dashboardURL) }
    @objc private func quit() { NSApp.terminate(nil) }
}

func runUpdateCommand(_ args: [String]) -> Int32 {
    guard args.contains("--primary") || args.contains("--secondary") ||
          args.contains("--five") || args.contains("--week") ||
          args.contains("--clear-primary") || args.contains("--clear-secondary") else { return 2 }
    let folder = dataFolder()
    let fileURL = folder.appendingPathComponent("usage.json")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var value = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(UsageSnapshot.self, from: $0) } ?? .empty
    var index = 0
    while index < args.count {
        let key = args[index]
        if key == "--clear-primary" {
            value.fiveUsed = nil
            value.fiveReset = nil
            value.primaryDurationMins = nil
            index += 1
            continue
        }
        if key == "--clear-secondary" {
            value.weekUsed = nil
            value.weekReset = nil
            value.secondaryDurationMins = nil
            index += 1
            continue
        }
        guard index + 1 < args.count else { fputs("Missing value for \(key)\n", stderr); return 2 }
        let raw = args[index + 1]
        switch key {
        case "--primary", "--five":
            guard let number = Double(raw), (0...100).contains(number) else { fputs("Primary usage must be 0–100\n", stderr); return 2 }
            value.fiveUsed = number
        case "--secondary", "--week":
            guard let number = Double(raw), (0...100).contains(number) else { fputs("Secondary usage must be 0–100\n", stderr); return 2 }
            value.weekUsed = number
        case "--primary-reset", "--five-reset":
            guard let time = TimeInterval(raw) else { fputs("Primary reset must be a Unix timestamp\n", stderr); return 2 }
            value.fiveReset = Date(timeIntervalSince1970: time)
        case "--secondary-reset", "--week-reset":
            guard let time = TimeInterval(raw) else { fputs("Secondary reset must be a Unix timestamp\n", stderr); return 2 }
            value.weekReset = Date(timeIntervalSince1970: time)
        default:
            fputs("Unknown option: \(key)\n", stderr)
            return 2
        }
        index += 2
    }
    value.updatedAt = Date()
    value.source = "快捷指令更新"
    do {
        try JSONEncoder().encode(value).write(to: fileURL, options: .atomic)
        print("Usage updated")
        return 0
    } catch {
        fputs("Could not save usage: \(error)\n", stderr)
        return 1
    }
}

func runRefreshCommand() -> Int32 {
    switch UsageFetcher.fetch() {
    case .failure(let message):
        fputs("Could not refresh usage: \(message)\n", stderr)
        return 1
    case .success(let value):
        let folder = dataFolder()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: folder.appendingPathComponent("usage.json"), options: .atomic)
            print("Usage refreshed: primary \(percentText(value.fiveUsed)), secondary \(percentText(value.weekUsed))")
            return 0
        } catch {
            fputs("Could not save usage: \(error)\n", stderr)
            return 1
        }
    }
}

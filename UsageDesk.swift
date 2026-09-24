import AppKit
import Darwin
import SwiftUI

private let dashboardURL = URL(string: "https://chatgpt.com/codex/settings/usage")!

private func dataFolder() -> URL {
    if let override = ProcessInfo.processInfo.environment["USAGEDESK_DATA_DIR"], !override.isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("UsageDesk", isDirectory: true)
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
        if let path = ProcessInfo.processInfo.environment["USAGEDESK_TEST_CODEX"] {
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

private func windowTitle(_ minutes: Int?, fallback: String) -> String {
    guard let minutes, minutes > 0 else { return fallback }
    if minutes == 10_080 { return "每周" }
    if minutes % 10_080 == 0 { return "\(minutes / 10_080) 周" }
    if minutes % 1_440 == 0 { return "\(minutes / 1_440) 天" }
    if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
    return "\(minutes) 分钟"
}

private func resetText(_ date: Date?) -> String {
    guard let date else { return "重置时间未填" }
    let format = DateFormatter()
    format.locale = Locale(identifier: "zh_CN")
    format.dateFormat = "M月d日 HH:mm 重置"
    return format.string(from: date)
}

private func updatedText(_ date: Date?) -> String {
    guard let date else { return "尚未录入" }
    let format = DateFormatter()
    format.locale = Locale(identifier: "zh_CN")
    format.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm:ss" : "M月d日 HH:mm:ss"
    return "\(format.string(from: date)) 更新"
}

struct MeterRow: View {
    let title: String
    let symbol: String
    let used: Double?
    let reset: Date?
    let tint: Color

    private var remaining: Double? { used.map { max(0, 100 - $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("剩余")
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
                Text(used == nil ? "等待用量数据" : "已用 \(percentText(used))")
                Spacer()
                Text(resetText(reset))
            }
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.65))
        }
    }
}

final class NativeDragHandle: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 64, height: 27) }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
        window?.saveFrame(usingName: "UsageDeskWindow")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
        let label = NSAttributedString(string: "☷ 拖动", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.72)
        ])
        let size = label.size()
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                               y: (bounds.height - size.height) / 2))
    }
}

struct DragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NativeDragHandle { NativeDragHandle() }
    func updateNSView(_ nsView: NativeDragHandle, context: Context) {}
}

struct WidgetCard: View {
    @ObservedObject var store: UsageStore
    let onRefresh: () -> Void
    @State private var showEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack(spacing: 10) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color(red: 0.53, green: 0.94, blue: 0.83))
                    .frame(width: 31, height: 31)
                    .background(.white.opacity(0.11), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex 用量")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                    Text(updatedText(store.snapshot.updatedAt))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.57))
                }
                Spacer()
                DragHandle()
                    .frame(width: 64, height: 27)
                    .help("按住这里拖动卡片")
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.8))
                .disabled(store.isRefreshing)
                .help("立即刷新用量")
                Button { showEditor = true } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.8))
                .help("更新用量")
            }

            if let used = store.snapshot.fiveUsed {
                MeterRow(title: windowTitle(store.snapshot.primaryDurationMins, fallback: "主要额度"),
                         symbol: "clock", used: used, reset: store.snapshot.fiveReset,
                         tint: Color(red: 0.41, green: 0.91, blue: 0.77))
            }
            if let used = store.snapshot.weekUsed {
                MeterRow(title: windowTitle(store.snapshot.secondaryDurationMins, fallback: "附加额度"),
                         symbol: "clock", used: used, reset: store.snapshot.weekReset,
                         tint: Color(red: 0.59, green: 0.70, blue: 1.0))
            }
            if store.snapshot.fiveUsed == nil && store.snapshot.weekUsed == nil {
                Text(store.isRefreshing ? "正在读取本机额度…" : "当前账户没有可显示的用量窗口")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, minHeight: 95)
            }

            HStack {
                Text(store.isRefreshing ? "正在同步…" : (store.lastError == nil ?
                     (store.snapshot.source ?? "用量快照") : "同步失败 · 显示上次数据"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.44))
                Spacer()
                Button("打开官方面板 ↗") { NSWorkspace.shared.open(dashboardURL) }
                    .buttonStyle(.plain)
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
        .sheet(isPresented: $showEditor) { UsageEditor(store: store) }
    }
}

struct UsageEditor: View {
    @ObservedObject var store: UsageStore
    @Environment(\.dismiss) private var dismiss
    @State private var five: Double
    @State private var week: Double
    @State private var fiveReset: Date
    @State private var weekReset: Date
    @State private var showPrimary: Bool
    @State private var showSecondary: Bool
    @State private var hasFiveReset: Bool
    @State private var hasWeekReset: Bool

    init(store: UsageStore) {
        self.store = store
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
            Text("更新用量")
                .font(.title3.bold())
            Text("填入官方用量面板显示的已用百分比。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(windowTitle(store.snapshot.primaryDurationMins, fallback: "主要额度"), isOn: $showPrimary)
            if showPrimary {
                HStack {
                    Text("已用")
                    Spacer()
                    TextField("0–100", value: $five, format: .number.precision(.fractionLength(0)))
                        .frame(width: 65)
                        .multilineTextAlignment(.trailing)
                    Text("%")
                }
                Toggle("设置重置时间", isOn: $hasFiveReset)
                if hasFiveReset {
                    DatePicker("", selection: $fiveReset, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                }
            }
            Toggle(windowTitle(store.snapshot.secondaryDurationMins, fallback: "附加额度"), isOn: $showSecondary)
            if showSecondary {
                HStack {
                    Text("已用")
                    Spacer()
                    TextField("0–100", value: $week, format: .number.precision(.fractionLength(0)))
                        .frame(width: 65)
                        .multilineTextAlignment(.trailing)
                    Text("%")
                }
                Toggle("设置重置时间", isOn: $hasWeekReset)
                if hasWeekReset {
                    DatePicker("", selection: $weekReset, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
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

final class CardWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var window: CardWindow!
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?
    private var refreshTimer: Timer?
    private var nextRefreshAt = Date.distantPast
    private var failureCount = 0
    private var pinItem: NSMenuItem!
    private var autoItem: NSMenuItem!
    private var intervalItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        window = CardWindow(contentRect: NSRect(x: 0, y: 0, width: 330, height: 268),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: WidgetCard(store: store, onRefresh: { [weak self] in
            self?.refreshUsage()
        }))
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
        window.makeKeyAndOrderFront(nil)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Codex 用量")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "显示 / 隐藏小组件", action: #selector(toggleWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "立即刷新用量", action: #selector(refreshNow), keyEquivalent: ""))
        pinItem = NSMenuItem(title: "始终置顶", action: #selector(togglePin), keyEquivalent: "")
        pinItem.state = keepOnTop ? .on : .off
        menu.addItem(pinItem)
        autoItem = NSMenuItem(title: "自动刷新用量", action: #selector(toggleAutoRefresh), keyEquivalent: "")
        autoItem.state = autoRefresh ? .on : .off
        menu.addItem(autoItem)
        let intervalItem = NSMenuItem(title: "刷新间隔", action: nil, keyEquivalent: "")
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
        menu.addItem(NSMenuItem(title: "打开官方用量面板", action: #selector(openDashboard), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu

        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.store.reload() }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.autoRefresh, Date() >= self.nextRefreshAt else { return }
                self.refreshUsage()
            }
        }
        if autoRefresh { refreshUsage() }
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

    private func updateIntervalChecks() {
        let presets = [10.0, 30.0, 60.0, 300.0]
        for (index, item) in intervalItems.enumerated() {
            item.state = index < presets.count
                ? (refreshInterval == presets[index] ? .on : .off)
                : (presets.contains(refreshInterval) ? .off : .on)
        }
        intervalItems.last?.title = presets.contains(refreshInterval)
            ? "自定义…" : "自定义…（\(Int(refreshInterval)) 秒）"
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

    @objc private func refreshNow() { refreshUsage() }

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
        if next { refreshUsage() }
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

let args = Array(CommandLine.arguments.dropFirst())
if args == ["--refresh"] { exit(runRefreshCommand()) }
if !args.isEmpty { exit(runUpdateCommand(args)) }
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppController()
    app.delegate = delegate
    app.run()
}

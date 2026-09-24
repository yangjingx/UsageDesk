import Combine
import Foundation
import Security

struct DeepSeekBalance: Codable, Sendable {
    let currency: String
    let total: Decimal
    let granted: Decimal
    let toppedUp: Decimal
}

struct DeepSeekSnapshot: Codable, Sendable {
    let isAvailable: Bool
    let balances: [DeepSeekBalance]
    let updatedAt: Date
}

enum DeepSeekCredential {
    #if USAGEDESK_TEST
    private static let service = "com.local.usagedesk.test.deepseek.api-key"
    #elseif USAGEDESK_PREVIEW
    private static let service = "com.local.usagedesk.preview.deepseek.api-key"
    #else
    private static let service = "com.local.usagedesk.deepseek.api-key"
    #endif
    private static let account = "DeepSeek Open Platform"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        #if USAGEDESK_TEST
        if Bundle.main.object(forInfoDictionaryKey: "UsageDeskTestDeepSeekResponse") != nil {
            return "demo-key-only"
        }
        #endif
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        var attributes = query
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess { return true }
        guard status == errSecDuplicateItem else { return false }
        return SecItemUpdate(query as CFDictionary,
                             [kSecValueData as String: data] as CFDictionary) == errSecSuccess
    }

    @discardableResult
    static func delete() -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

enum DeepSeekAPIError: Error {
    case invalidResponse
    case invalidAmount
    case unauthorized
    case unavailable
    case server(Int)
}

private struct BalanceResponse: Decodable {
    let is_available: Bool
    let balance_infos: [BalanceInfo]
}

private struct BalanceInfo: Decodable {
    let currency: String
    let total_balance: String
    let granted_balance: String
    let topped_up_balance: String
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum DeepSeekAPI {
    static func parse(_ data: Data, at date: Date = Date()) throws -> DeepSeekSnapshot {
        let response = try JSONDecoder().decode(BalanceResponse.self, from: data)
        let locale = Locale(identifier: "en_US_POSIX")
        let balances = try response.balance_infos.map { info -> DeepSeekBalance in
            guard let total = Decimal(string: info.total_balance, locale: locale),
                  let granted = Decimal(string: info.granted_balance, locale: locale),
                  let toppedUp = Decimal(string: info.topped_up_balance, locale: locale),
                  !info.currency.isEmpty else { throw DeepSeekAPIError.invalidAmount }
            return DeepSeekBalance(currency: info.currency, total: total,
                                   granted: granted, toppedUp: toppedUp)
        }
        return DeepSeekSnapshot(isAvailable: response.is_available,
                                balances: balances, updatedAt: date)
    }

    static func fetch(key: String) async throws -> DeepSeekSnapshot {
        #if USAGEDESK_TEST
        if let file = ProcessInfo.processInfo.environment["USAGEDESK_TEST_DEEPSEEK_RESPONSE"]
            ?? (Bundle.main.object(forInfoDictionaryKey: "UsageDeskTestDeepSeekResponse") as? String) {
            return try parse(Data(contentsOf: URL(fileURLWithPath: file)))
        }
        #endif
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 12
        let session = URLSession(configuration: configuration, delegate: RejectRedirects(),
                                 delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              response.url?.scheme == "https",
              response.url?.host == "api.deepseek.com" else { throw DeepSeekAPIError.invalidResponse }
        switch response.statusCode {
        case 200: return try parse(data)
        case 401, 403: throw DeepSeekAPIError.unauthorized
        case 402: throw DeepSeekAPIError.unavailable
        default: throw DeepSeekAPIError.server(response.statusCode)
        }
    }
}

@MainActor
final class DeepSeekStore: ObservableObject {
    @Published var snapshot: DeepSeekSnapshot?
    @Published var isRefreshing = false
    @Published var lastError: String?
    @Published var hasCredential: Bool
    private let fileURL: URL

    init(folder: URL) {
        fileURL = folder.appendingPathComponent("deepseek.json")
        snapshot = (try? Data(contentsOf: fileURL)).flatMap {
            try? JSONDecoder().decode(DeepSeekSnapshot.self, from: $0)
        }
        hasCredential = false
        Task { [weak self] in
            let available = await Task.detached(priority: .utility) {
                DeepSeekCredential.read() != nil
            }.value
            self?.hasCredential = available
        }
    }

    func save(_ value: DeepSeekSnapshot) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: fileURL, options: .atomic)
        }
        snapshot = value
        lastError = nil
    }

    func replaceCredential(_ key: String) async -> Bool {
        let saved = await Task.detached(priority: .userInitiated) {
            DeepSeekCredential.save(key)
        }.value
        guard saved else { return false }
        try? FileManager.default.removeItem(at: fileURL)
        snapshot = nil
        lastError = nil
        hasCredential = true
        return true
    }

    func removeCredential() async -> Bool {
        let deleted = await Task.detached(priority: .userInitiated) {
            DeepSeekCredential.delete()
        }.value
        guard deleted else { return false }
        try? FileManager.default.removeItem(at: fileURL)
        snapshot = nil
        lastError = nil
        hasCredential = false
        return true
    }
}

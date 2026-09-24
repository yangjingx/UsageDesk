import Combine
import Foundation

enum CardLayout: String, CaseIterable {
    case switchCards
    case vertical
}

enum ProviderID: String, CaseIterable {
    case codex
    case deepSeek
}

enum AppLanguage: String, CaseIterable {
    case chinese
    case english
}

@MainActor
final class AppPreferences: ObservableObject {
    @Published var showSettings = false
    @Published var layout: CardLayout {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: "cardLayout") }
    }
    @Published var selectedProvider: ProviderID {
        didSet { UserDefaults.standard.set(selectedProvider.rawValue, forKey: "selectedProvider") }
    }
    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "language") }
    }

    init() {
        #if USAGEDESK_TEST
        let testLayout = Bundle.main.object(forInfoDictionaryKey: "UsageDeskTestLayout") as? String
        #else
        let testLayout: String? = nil
        #endif
        layout = CardLayout(rawValue: testLayout ?? UserDefaults.standard.string(forKey: "cardLayout") ?? "") ?? .switchCards
        selectedProvider = ProviderID(rawValue: UserDefaults.standard.string(forKey: "selectedProvider") ?? "") ?? .codex
        language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "")
            ?? (Locale.current.language.languageCode?.identifier == "zh" ? .chinese : .english)
    }

    func text(_ chinese: String, _ english: String) -> String {
        language == .chinese ? chinese : english
    }
}

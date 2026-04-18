import Foundation

enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case traditionalChinese
    case english

    var id: String { rawValue }

    var label: String {
        switch self {
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        }
    }
}

enum L10n {
    static let languageDefaultsKey = "app_language"

    static func currentLanguage() -> AppLanguage {
        let rawValue = UserDefaults.standard.string(forKey: languageDefaultsKey)
        return rawValue.flatMap(AppLanguage.init(rawValue:)) ?? .traditionalChinese
    }

    static func setCurrentLanguage(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: languageDefaultsKey)
    }

    static func pair(_ zh: String, _ en: String, language: AppLanguage? = nil) -> String {
        let language = language ?? currentLanguage()
        switch language {
        case .traditionalChinese:
            return zh
        case .english:
            return en
        }
    }
}

func localizedAppText(_ zh: String, _ en: String) -> String {
    L10n.pair(zh, en)
}

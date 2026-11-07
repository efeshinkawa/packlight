import Foundation

/// UI languages. Strings live in Swift dictionaries (Translations.swift) instead of a
/// string catalog or resource bundle, so the app builds with plain `swift build`.
/// `rawValue` is the code stored in UserDefaults under `Key.language`.
enum Lang: String, CaseIterable, Identifiable {
    case system
    case en, tr, es
    case zhHans = "zh-Hans"
    case hi, ar, fr
    case ptBR = "pt-BR"
    case de, ja, ru, ko
    var id: String { rawValue }

    /// Every concrete language, in picker order.
    static var languages: [Lang] { allCases.filter { $0 != .system } }

    static var current: Lang {
        let stored = Lang(rawValue: UserDefaults.standard.string(forKey: Key.language) ?? "") ?? .system
        return stored == .system ? fromSystem() : stored
    }

    private static func fromSystem() -> Lang {
        guard let pref = Locale.preferredLanguages.first?.lowercased() else { return .en }
        if pref.hasPrefix("zh") { return .zhHans }
        if pref.hasPrefix("pt") { return .ptBR }
        let code = String(pref.prefix { $0 != "-" && $0 != "_" })
        return languages.first { $0.rawValue == code } ?? .en
    }

    var nativeName: String {
        switch self {
        case .system: return T("System")
        case .en: return "English"
        case .tr: return "Türkçe"
        case .es: return "Español"
        case .zhHans: return "简体中文"
        case .hi: return "हिन्दी"
        case .ar: return "العربية"
        case .fr: return "Français"
        case .ptBR: return "Português (Brasil)"
        case .de: return "Deutsch"
        case .ja: return "日本語"
        case .ru: return "Русский"
        case .ko: return "한국어"
        }
    }

    var isRTL: Bool { self == .ar }
}

/// Looks up `key` (the English printf-style format string) for the current language,
/// falls back to English, then formats. Numbers use POSIX formatting (e.g. "3.5"),
/// matching what the app has always shown.
func T(_ key: String, _ args: CVarArg...) -> String {
    let format = Translations.table(for: Lang.current)?[key] ?? key
    return String(format: format, locale: nil, arguments: args)
}

// Zweisprachig ohne .strings-Dateien: jeder Text steht als Paar (Deutsch, Englisch) direkt im Code.
// Deutsch, wenn die erste bevorzugte Systemsprache Deutsch ist, sonst Englisch.

import Foundation

enum AppLanguage: Equatable {
    case german
    case english

    static func resolve(preferredLanguages: [String]) -> AppLanguage {
        guard let first = preferredLanguages.first?.lowercased() else { return .english }
        return first.hasPrefix("de") ? .german : .english
    }

    static let current = resolve(preferredLanguages: Locale.preferredLanguages)
}

/// Gibt den Text in der Systemsprache zurück: `L("Verbinden", "Connect")`.
func L(_ german: String, _ english: String) -> String {
    AppLanguage.current == .german ? german : english
}

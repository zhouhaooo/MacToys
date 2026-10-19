// SPDX-License-Identifier: MIT
import Foundation
import Combine

final class AppLocale: ObservableObject {
    static let shared = AppLocale()
    @Published var revision = 0
}

func L(_ key: String) -> String {
    let language: String
    switch AppLanguage.current {
    case .chinese: language = "zh-Hans"
    case .english: language = "en"
    case .system: language = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-Hans" : "en"
    }
    guard let url = Bundle.main.url(forResource: language, withExtension: "lproj"),
          let bundle = Bundle(url: url) else { return key }
    return bundle.localizedString(forKey: key, value: key, table: nil)
}
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: AppLanguage.uiLocale, arguments: args)
}
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, chinese = "zh-Hans", english = "en"
    var id: Self { self }
    var title: String {
        switch self {
        case .system: L("跟随系统")
        case .chinese: "简体中文"
        case .english: "English"
        }
    }
    static var current: Self { UserDefaults.standard.string(forKey: "mactoys.language").flatMap(Self.init) ?? .system }
    func apply() {
        UserDefaults.standard.set(rawValue, forKey: "mactoys.language")
        AppLocale.shared.revision += 1
    }
    static var uiLocale: Locale {
        let language = current == .system ? Locale.preferredLanguages.first ?? "en" : current.rawValue
        return Locale(identifier: language)
    }
    static var isChinese: Bool { uiLocale.identifier.hasPrefix("zh") }
}

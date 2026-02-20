import Foundation

enum L10n {
    private static var bundle: Bundle {
        #if SWIFT_PACKAGE
        .module
        #else
        .main
        #endif
    }

    static func string(_ key: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: bundle, value: key, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        let format = string(key)
        return String(format: format, locale: .current, arguments: arguments)
    }
}

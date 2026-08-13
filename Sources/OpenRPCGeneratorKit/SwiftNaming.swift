import Foundation

/// Converts JSON names into Swift identifiers.
public enum SwiftNaming {
    static let keywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate",
        "func", "import", "init", "inout", "internal", "let", "open", "operator",
        "private", "protocol", "public", "rethrows", "static", "struct",
        "subscript", "typealias", "var", "break", "case", "catch", "continue",
        "default", "defer", "do", "else", "fallthrough", "for", "guard", "if",
        "in", "repeat", "return", "switch", "throw", "throws", "where", "while",
        "as", "any", "false", "is", "nil", "self", "Self", "super", "true",
        "try", "await", "async", "actor", "package", "some", "Type", "Protocol",
    ]

    /// Converts to a PascalCase type name. Example: `"pet store"` → `"PetStore"`
    public static func typeName(_ name: String) -> String {
        let joined = words(from: name).map(capitalizeFirst).joined()
        let result = sanitizeLeadingDigit(joined)
        return result.isEmpty ? "Value" : result
    }

    /// Converts to a camelCase member name, escaping keywords with backticks.
    /// Example: `"list_pets"` → `"listPets"`, `"class"` → `` "`class`" ``
    public static func memberName(_ name: String) -> String {
        let parts = words(from: name)
        guard let first = parts.first else { return "value" }
        let joined = lowercaseFirst(first) + parts.dropFirst().map(capitalizeFirst).joined()
        let result = sanitizeLeadingDigit(joined)
        if result.isEmpty { return "value" }
        return keywords.contains(result) ? "`\(result)`" : result
    }

    /// Converts to a member name that is unique within `used`, appending a
    /// numeric suffix on collision. The suffix is applied to the raw name
    /// *before* keyword escaping, so `"class"` collides into `"class2"`,
    /// never the invalid `` `class`2 ``.
    public static func uniqueMemberName(_ name: String, in used: inout Set<String>) -> String {
        var candidate = memberName(name)
        var suffix = 2
        while used.contains(candidate) {
            candidate = memberName(name + "\(suffix)")
            suffix += 1
        }
        used.insert(candidate)
        return candidate
    }

    /// Makes a name unique within `used` by appending a numeric suffix,
    /// without any other transformation. Used for already-valid identifiers
    /// such as type names and JSON component keys.
    public static func uniqueName(_ base: String, in used: inout Set<String>) -> String {
        var candidate = base
        var suffix = 2
        while used.contains(candidate) {
            candidate = "\(base)\(suffix)"
            suffix += 1
        }
        used.insert(candidate)
        return candidate
    }

    /// Splits on non-alphanumeric characters, preserving existing
    /// camelCase / PascalCase within each word.
    private static func words(from name: String) -> [String] {
        name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static func capitalizeFirst(_ word: String) -> String {
        guard let first = word.first else { return word }
        // Lowercase the tail of all-caps words (parts of SCREAMING_CASE).
        if word.count > 1, word.allSatisfy({ !$0.isLowercase }) {
            return String(first).uppercased() + word.dropFirst().lowercased()
        }
        return String(first).uppercased() + word.dropFirst()
    }

    private static func lowercaseFirst(_ word: String) -> String {
        // Lowercase a run of leading uppercase letters (an acronym) as a unit.
        // Example: "URLValue" → "urlValue"
        guard let first = word.first, first.isUppercase else { return word }
        let leadingUppercase = word.prefix(while: { $0.isUppercase })
        if leadingUppercase.count == word.count {
            return word.lowercased()
        }
        if leadingUppercase.count == 1 {
            return String(first).lowercased() + word.dropFirst()
        }
        // The last uppercase letter starts the next word, so keep it.
        let head = leadingUppercase.dropLast()
        return head.lowercased() + word.dropFirst(head.count)
    }

    private static func sanitizeLeadingDigit(_ name: String) -> String {
        guard let first = name.first, first.isNumber else { return name }
        return "_" + name
    }
}

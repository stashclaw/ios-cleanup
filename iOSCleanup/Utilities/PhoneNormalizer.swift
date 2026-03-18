import Foundation

struct PhoneNormalizer {
    /// Strip all non-digit characters, then normalize to E.164-ish.
    /// "+1 (555) 867-5309" → "15558675309"
    /// "555-867-5309"      → "5558675309"
    /// If < 7 digits, returns nil.
    static func normalize(_ raw: String) -> String? {
        let digits = raw.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
        let result = String(String.UnicodeScalarView(digits))
        guard result.count >= 7 else { return nil }
        if result.count == 11 && result.hasPrefix("1") {
            return result
        }
        if result.count == 10 {
            return "1" + result
        }
        return result
    }
}

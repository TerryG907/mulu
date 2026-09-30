import Foundation

/// Normalizes typed numbers: Chinese input methods produce full-width digits and punctuation
/// ("２２", "３，５，８－９", "5～7", "5至7"), which the parsers only accept in ASCII. Used by the
/// app's page and offset fields and the TOC page range (MuluOCR's parser stays ASCII-only).
public enum PageNumberInput {
    /// Trims whitespace and turns full-width digits into ASCII, so "２２" is accepted as 22.
    public static func normalize(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map(asciiDigit)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A page list as `parsePageList` reads it: ，、；; → ","; ～ ~ — – － − 至 到 → "-";
    /// full-width digits → ASCII; every space dropped. "3，5，8－9" → "3,5,8-9".
    public static func normalizeRange(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "，", "、", "；", ";", "﹐", "､": out.append(",")  // strings:ignore
            case "～", "~", "〜", "—", "–", "－", "−", "‐", "‑", "至", "到": out.append("-")  // strings:ignore
            case _ where scalar.properties.isWhitespace: continue
            default: out.append(asciiDigit(scalar))
            }
        }
        return String(out)
    }

    /// A signed integer typed in any of these ways: "8", "+8", "-3", "－３", "−3", "＋８".
    public static func integer(_ text: String) -> Int? {
        var s = normalize(text)
        s = s.replacingOccurrences(of: "－", with: "-").replacingOccurrences(of: "−", with: "-")  // strings:ignore
            .replacingOccurrences(of: "＋", with: "+")  // strings:ignore
        if s.hasPrefix("+") { s.removeFirst() }
        return Int(s)
    }

    private static func asciiDigit(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        if (0xFF10...0xFF19).contains(scalar.value), let ascii = Unicode.Scalar(scalar.value - 0xFF10 + 0x30) {
            return ascii
        }
        return scalar
    }
}

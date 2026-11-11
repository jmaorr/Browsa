import Foundation

/// Sums and unit conversions typed into the command bar ("12*7+3", "15% of 80", "5 km in mi",
/// "180 c to f"). Worked out on the Mac; Return copies the answer.
public enum Calculator {
    public struct Answer: Sendable, Equatable {
        /// "87", "3.11 mi".
        public let text: String
        /// What was understood, for the subtitle: "12 × 7 + 3".
        public let expression: String
    }

    public static func answer(for input: String) -> Answer? {
        let t = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard t.count >= 2, t.count <= 120 else { return nil }
        if let a = conversion(t) { return a }
        if let a = percentOf(t) { return a }
        // Needs an operator, so "2026" or "42" alone stays a search.
        let body = t.hasPrefix("=") ? String(t.dropFirst()) : t
        guard body.rangeOfCharacter(from: CharacterSet(charactersIn: "+-*/^×÷()")) != nil
                || ["sqrt", "sin", "cos", "tan", "log", "ln", "pi"].contains(where: body.contains) else { return nil }
        // Something like "2024-11-11" or "1-800-flowers" isn't a sum.
        if body.range(of: #"^\d{4}-\d{1,2}-\d{1,2}$"#, options: .regularExpression) != nil { return nil }
        var parser = Parser(body)
        guard let value = parser.parse(), value.isFinite else { return nil }
        let pretty = body.replacingOccurrences(of: "*", with: " × ").replacingOccurrences(of: "/", with: " ÷ ")
            .replacingOccurrences(of: "+", with: " + ").replacingOccurrences(of: "  ", with: " ")
        return Answer(text: format(value), expression: pretty.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Formatting

    static func format(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 6
        f.usesGroupingSeparator = false
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    // MARK: "15% of 80"

    private static func percentOf(_ t: String) -> Answer? {
        let parts = t.components(separatedBy: "% of ")
        guard parts.count == 2, let p = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let n = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return Answer(text: format(p / 100 * n), expression: "\(format(p))% of \(format(n))")
    }

    // MARK: Units

    private struct Unit: Sendable {
        let names: [String]
        let symbol: String
        let kind: String
        /// Multiplier to the kind's base unit (temperatures use `toBase`/`fromBase`).
        let factor: Double
        var toBase: (@Sendable (Double) -> Double)? = nil
        var fromBase: (@Sendable (Double) -> Double)? = nil
    }

    private static let units: [Unit] = [
        Unit(names: ["km", "kilometre", "kilometres", "kilometer", "kilometers"], symbol: "km", kind: "length", factor: 1000),
        Unit(names: ["m", "metre", "metres", "meter", "meters"], symbol: "m", kind: "length", factor: 1),
        Unit(names: ["cm", "centimetre", "centimetres", "centimeter", "centimeters"], symbol: "cm", kind: "length", factor: 0.01),
        Unit(names: ["mm"], symbol: "mm", kind: "length", factor: 0.001),
        Unit(names: ["mi", "mile", "miles"], symbol: "mi", kind: "length", factor: 1609.344),
        Unit(names: ["ft", "foot", "feet"], symbol: "ft", kind: "length", factor: 0.3048),
        Unit(names: ["in", "inch", "inches"], symbol: "in", kind: "length", factor: 0.0254),
        Unit(names: ["kg", "kilo", "kilos", "kilogram", "kilograms"], symbol: "kg", kind: "mass", factor: 1),
        Unit(names: ["g", "gram", "grams"], symbol: "g", kind: "mass", factor: 0.001),
        Unit(names: ["lb", "lbs", "pound", "pounds"], symbol: "lb", kind: "mass", factor: 0.45359237),
        Unit(names: ["oz", "ounce", "ounces"], symbol: "oz", kind: "mass", factor: 0.028349523125),
        Unit(names: ["l", "litre", "litres", "liter", "liters"], symbol: "L", kind: "volume", factor: 1),
        Unit(names: ["ml"], symbol: "mL", kind: "volume", factor: 0.001),
        Unit(names: ["gal", "gallon", "gallons"], symbol: "gal", kind: "volume", factor: 3.785411784),
        Unit(names: ["cup", "cups"], symbol: "cups", kind: "volume", factor: 0.2365882365),
        Unit(names: ["c", "°c", "celsius"], symbol: "°C", kind: "temp", factor: 1, toBase: { $0 }, fromBase: { $0 }),
        Unit(names: ["f", "°f", "fahrenheit"], symbol: "°F", kind: "temp", factor: 1,
             toBase: { ($0 - 32) * 5 / 9 }, fromBase: { $0 * 9 / 5 + 32 }),
        Unit(names: ["kb"], symbol: "KB", kind: "data", factor: 1_000),
        Unit(names: ["mb"], symbol: "MB", kind: "data", factor: 1_000_000),
        Unit(names: ["gb"], symbol: "GB", kind: "data", factor: 1_000_000_000),
        Unit(names: ["tb"], symbol: "TB", kind: "data", factor: 1_000_000_000_000),
    ]

    private static func unit(_ name: String) -> Unit? { units.first { $0.names.contains(name) } }

    /// "5 km in mi", "5km to miles", "180 f in c".
    private static func conversion(_ t: String) -> Answer? {
        let pattern = #"^(-?[\d.]+)\s*([a-z°]+)\s+(?:in|to|as)\s+([a-z°]+)$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), m.numberOfRanges == 4,
              let r1 = Range(m.range(at: 1), in: t), let r2 = Range(m.range(at: 2), in: t), let r3 = Range(m.range(at: 3), in: t),
              let value = Double(t[r1]), let from = unit(String(t[r2])), let to = unit(String(t[r3])),
              from.kind == to.kind else { return nil }
        let base = from.toBase?(value) ?? value * from.factor
        let out = to.fromBase?(base) ?? base / to.factor
        let rounded = (out * 1000).rounded() / 1000
        return Answer(text: "\(format(rounded)) \(to.symbol)", expression: "\(format(value)) \(from.symbol) in \(to.symbol)")
    }

    // MARK: Parser

    /// Recursive descent: + − × ÷ ^, brackets, unary minus, pi, e, sqrt/sin/cos/tan/log/ln.
    private struct Parser {
        private let chars: [Character]
        private var i = 0

        init(_ text: String) {
            chars = Array(text.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
                .replacingOccurrences(of: ",", with: "").filter { !$0.isWhitespace })
        }

        mutating func parse() -> Double? {
            guard let v = expression(), i == chars.count else { return nil }
            return v
        }

        private var peek: Character? { i < chars.count ? chars[i] : nil }

        private mutating func expression() -> Double? {
            guard var v = term() else { return nil }
            while let c = peek, c == "+" || c == "-" {
                i += 1
                guard let r = term() else { return nil }
                v = c == "+" ? v + r : v - r
            }
            return v
        }

        private mutating func term() -> Double? {
            guard var v = power() else { return nil }
            while let c = peek, c == "*" || c == "/" || c == "%" {
                i += 1
                guard let r = power() else { return nil }
                switch c {
                case "*": v *= r
                case "/": v /= r
                default: v = v.truncatingRemainder(dividingBy: r)
                }
            }
            return v
        }

        private mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if peek == "^" {
                i += 1
                guard let exp = power() else { return nil }
                return pow(base, exp)
            }
            return base
        }

        private mutating func unary() -> Double? {
            if peek == "-" { i += 1; return unary().map { -$0 } }
            if peek == "+" { i += 1; return unary() }
            return primary()
        }

        private mutating func primary() -> Double? {
            guard let c = peek else { return nil }
            if c == "(" {
                i += 1
                let v = expression()
                guard peek == ")" else { return nil }
                i += 1
                return v
            }
            if c.isNumber || c == "." {
                let start = i
                while let d = peek, d.isNumber || d == "." { i += 1 }
                return Double(String(chars[start..<i]))
            }
            if c.isLetter {
                let start = i
                while let d = peek, d.isLetter { i += 1 }
                let name = String(chars[start..<i])
                switch name {
                case "pi": return .pi
                case "e": return M_E
                default:
                    guard peek == "(" , let arg = primary() else { return nil }
                    switch name {
                    case "sqrt": return arg.squareRoot()
                    case "sin": return sin(arg)
                    case "cos": return cos(arg)
                    case "tan": return tan(arg)
                    case "log": return log10(arg)
                    case "ln": return log(arg)
                    case "abs": return abs(arg)
                    default: return nil
                    }
                }
            }
            return nil
        }
    }
}

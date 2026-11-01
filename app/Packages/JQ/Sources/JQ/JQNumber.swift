/// A jq number.
///
/// jq keeps the text of a number it reads, so a number that passes through a program unchanged
/// stays exact, such as an integer beyond 2^53. Numbers jq computes are doubles. Two numbers are
/// equal when they have the same decimal value, so `1`, `1.0` and `1E+0` are equal.
public struct JQNumber: Sendable, Hashable, CustomStringConvertible {
    /// The number's text as jq keeps it, or nil for a double.
    let literal: String?

    /// The nearest double.
    public let doubleValue: Double

    /// An exact integer.
    public init(_ value: Int) {
        literal = String(value)
        doubleValue = Double(value)
    }

    /// A double, as jq's arithmetic produces.
    public init(_ value: Double) {
        literal = nil
        doubleValue = value
    }

    init(literal: String?, doubleValue: Double) {
        self.literal = literal
        self.doubleValue = doubleValue
    }

    /// The exact value, when the number is whole and fits in an `Int`.
    public var intValue: Int? {
        guard literal != nil else {
            return Int(exactly: doubleValue)
        }
        guard case .finite(let negative, let digits, let exponent) = decimal else {
            return nil
        }
        if digits.isEmpty {
            return 0
        }
        guard exponent >= 0, digits.count + exponent <= 19 else {
            return nil
        }
        return Int((negative ? "-" : "") + digits + String(repeating: "0", count: exponent))
    }

    /// The number as jq prints it.
    public var description: String {
        literal ?? JV.dump(JV.make(self), flags: 0)
    }

    public static func == (lhs: JQNumber, rhs: JQNumber) -> Bool {
        lhs.decimal == rhs.decimal
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(decimal)
    }

    /// The value in one spelling: significant digits without leading or trailing zeros,
    /// times ten to the exponent. Zero has no digits.
    private enum Decimal: Hashable {
        case finite(negative: Bool, digits: String, exponent: Int)
        case infinity(negative: Bool)
        case nan
    }

    private var decimal: Decimal {
        if let literal, let decimal = Self.decimal(literal) {
            return decimal
        }
        if doubleValue.isNaN {
            return .nan
        }
        if doubleValue.isInfinite {
            return .infinity(negative: doubleValue < 0)
        }
        // Swift spells a double with the shortest digits that round-trip, as jq prints it.
        return Self.decimal(doubleValue.description) ?? .nan
    }

    /// Reads a JSON number, or a number as decNumber or Swift spells one.
    private static func decimal(_ text: String) -> Decimal? {
        let bytes = Array(text.utf8)
        var index = 0
        func take(_ character: Unicode.Scalar) -> Bool {
            guard index < bytes.count, bytes[index] == UInt8(ascii: character) else {
                return false
            }
            index += 1
            return true
        }
        func takeDigit() -> UInt8? {
            guard index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) else {
                return nil
            }
            index += 1
            return bytes[index - 1]
        }

        let negative = take("-")
        if !negative {
            _ = take("+")
        }
        var digits: [UInt8] = []
        var exponent = 0
        while let digit = takeDigit() {
            digits.append(digit)
        }
        if take(".") {
            while let digit = takeDigit() {
                digits.append(digit)
                exponent -= 1
            }
        }
        guard !digits.isEmpty else {
            return nil
        }
        if take("e") || take("E") {
            let negativeExponent = take("-")
            if !negativeExponent {
                _ = take("+")
            }
            var value = 0
            var sawDigit = false
            while let digit = takeDigit() {
                guard value < 1_000_000_000_000 else {
                    return nil
                }
                value = value * 10 + Int(digit - UInt8(ascii: "0"))
                sawDigit = true
            }
            guard sawDigit else {
                return nil
            }
            exponent += negativeExponent ? -value : value
        }
        guard index == bytes.count else {
            return nil
        }
        let zero = UInt8(ascii: "0")
        guard let first = digits.firstIndex(where: { $0 != zero }),
              let last = digits.lastIndex(where: { $0 != zero })
        else {
            return .finite(negative: false, digits: "", exponent: 0)
        }
        exponent += digits.count - 1 - last
        return .finite(negative: negative, digits: String(decoding: digits[first...last], as: UTF8.self), exponent: exponent)
    }
}

extension JQNumber: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    public init(integerLiteral value: Int) {
        self.init(value)
    }

    public init(floatLiteral value: Double) {
        self.init(value)
    }
}

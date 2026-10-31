import CJQ
import Foundation

/// A JSON value, as jq programs take and produce them.
public enum JQValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(JQNumber)
    case string(String)
    case array([JQValue])
    case object(JQObject)
}

extension JQValue {
    /// Parses JSON with jq's parser. In `.json` mode the text is one value; in `.jsonl` mode
    /// each non-empty line is a value, and the result is the array of them.
    public init(json: Data, mode: JQInputMode = .json) throws(JQError) {
        guard json.count <= Int(Int32.max) else {
            throw .invalidJSON("The input is larger than 2 GiB")
        }
        let parsed = json.withUnsafeBytes { bytes in
            Result { () throws(JQError) -> JQValue in
                switch mode {
                case .json:
                    guard let value = try JSONText.value(in: bytes) else {
                        throw .invalidJSON("Expected JSON value")
                    }
                    return value
                case .jsonl:
                    return .array(try JSONText.lines(in: bytes))
                }
            }
        }
        self = try parsed.get()
    }

    /// Parses JSON text; see `init(json:mode:)` for the modes.
    public init(json: String, mode: JQInputMode = .json) throws(JQError) {
        try self.init(json: Data(json.utf8), mode: mode)
    }

    /// The value as JSON, printed by jq: compact as `jq -c`, or indented by two spaces as `jq`.
    public func jsonData(pretty: Bool = false) -> Data {
        JV.dumpData(JV.make(self), flags: pretty ? JV.prettyFlags : 0)
    }

    /// The value as JSON text; see `jsonData(pretty:)`.
    public func jsonString(pretty: Bool = false) -> String {
        JV.dump(JV.make(self), flags: pretty ? JV.prettyFlags : 0)
    }
}

extension JQValue: CustomStringConvertible {
    /// The value as compact JSON.
    public var description: String {
        jsonString()
    }
}

extension JQValue: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }

    public init(integerLiteral value: Int) {
        self = .number(JQNumber(value))
    }

    public init(floatLiteral value: Double) {
        self = .number(JQNumber(value))
    }

    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public init(arrayLiteral elements: JQValue...) {
        self = .array(elements)
    }

    public init(dictionaryLiteral elements: (String, JQValue)...) {
        self = .object(JQObject(elements))
    }
}

/// JSON text through jq's parser.
enum JSONText {
    /// The one value in `bytes`, or nil when they hold only whitespace.
    static func value(in bytes: UnsafeRawBufferPointer) throws(JQError) -> JQValue? {
        guard let base = bytes.baseAddress, !bytes.isEmpty else {
            return nil
        }
        guard let parser = jv_parser_new(0) else {
            throw .invalidJSON("Out of memory")
        }
        defer { jv_parser_free(parser) }
        jv_parser_set_buf(parser, base.assumingMemoryBound(to: CChar.self), Int32(bytes.count), 0)

        let first = jv_parser_next(parser)
        guard jv_get_kind(first) != JV_KIND_INVALID else {
            if jv_invalid_has_msg(jv_copy(first)) != 0 {
                throw .invalidJSON(JV.message(jv_invalid_get_msg(first)))
            }
            jv_free(first)
            return nil
        }
        defer { jv_free(first) }

        let next = jv_parser_next(parser)
        if jv_get_kind(next) != JV_KIND_INVALID {
            jv_free(next)
            throw .invalidJSON("Unexpected extra JSON values")
        }
        if jv_invalid_has_msg(jv_copy(next)) != 0 {
            throw .invalidJSON(JV.message(jv_invalid_get_msg(next)))
        }
        jv_free(next)

        guard let value = JV.value(of: first) else {
            throw .invalidJSON("Exceeds depth limit for parsing (\(JV.maximumDepth) levels)")
        }
        return value
    }

    /// The values of the non-empty lines in `bytes`.
    static func lines(in bytes: UnsafeRawBufferPointer) throws(JQError) -> [JQValue] {
        var values: [JQValue] = []
        var start = 0
        var line = 1
        while start < bytes.count {
            let end = bytes[start...].firstIndex(of: UInt8(ascii: "\n")) ?? bytes.count
            do {
                if let value = try value(in: UnsafeRawBufferPointer(rebasing: bytes[start..<end])) {
                    values.append(value)
                }
            } catch {
                throw .invalidJSON(locate(error.message, line: line))
            }
            start = end + 1
            line += 1
        }
        return values
    }

    /// jq counts lines within the text it parses, which here is a single line.
    private static func locate(_ message: String, line: Int) -> String {
        guard let range = message.range(of: " at line 1, column ", options: .backwards) else {
            return "\(message) at line \(line)"
        }
        return message.replacingCharacters(in: range, with: " at line \(line), column ")
    }
}

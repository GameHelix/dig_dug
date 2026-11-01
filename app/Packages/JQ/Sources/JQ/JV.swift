import CJQ
import Foundation

/// Conversions between jq's `jv` and `JQValue`.
///
/// Most jv functions consume their arguments; `jv_copy` adds a reference. Functions here say
/// whether they borrow a jv, which the caller still frees, or consume it.
enum JV {
    /// Values from jq nest at most this deep. Swift releases, compares and hashes a `JQValue`
    /// recursively; this leaves at least three times the room on a 512 KB concurrency thread,
    /// even in a debug build.
    static let maximumDepth = 128

    static let prettyFlags = Int32(JV_PRINT_PRETTY.rawValue | JV_PRINT_SPACE1.rawValue)

    /// A new jv for `value`; the caller owns it. Works without recursion, so deep values do
    /// not use up the stack.
    static func make(_ value: JQValue) -> jv {
        var frames: [Builder] = []
        var next = value
        while true {
            var built: jv?
            switch next {
            case .null: built = jv_null()
            case .bool(let bool): built = bool ? jv_true() : jv_false()
            case .number(let number): built = make(number)
            case .string(let string): built = make(string)
            case .array(let elements): frames.append(Builder(elements))
            case .object(let members): frames.append(Builder(members))
            }
            while true {
                if let finished = built {
                    guard let top = frames.indices.last else {
                        return finished
                    }
                    frames[top].add(finished)
                    built = nil
                }
                guard let top = frames.indices.last else {
                    return jv_null()
                }
                if let child = frames[top].nextChild() {
                    next = child
                    break
                }
                built = frames.removeLast().container
            }
        }
    }

    /// A new jv for `number`, keeping its literal; the caller owns it.
    static func make(_ number: JQNumber) -> jv {
        if let literal = number.literal {
            let value = literal.withCString { jv_number_with_literal($0) }
            if jv_get_kind(value) == JV_KIND_NUMBER {
                return value
            }
            jv_free(value)
        }
        return jv_number(number.doubleValue)
    }

    /// A new jv string; the caller owns it.
    static func make(_ string: String) -> jv {
        var string = string
        return string.withUTF8 { utf8 in
            guard let base = utf8.baseAddress, !utf8.isEmpty else {
                return jv_string("")
            }
            precondition(utf8.count <= Int(Int32.max), "jq strings are limited to 2 GiB")
            return base.withMemoryRebound(to: CChar.self, capacity: utf8.count) {
                jv_string_sized($0, Int32(utf8.count))
            }
        }
    }

    /// The value of a jv it borrows, or nil when it nests deeper than `maximumDepth`. Works
    /// without recursion, so deep values do not use up the stack.
    static func value(of value: jv) -> JQValue? {
        var frames: [Reader] = []
        defer {
            for frame in frames {
                jv_free(frame.source)
            }
        }
        var next = jv_copy(value)
        while true {
            var finished: JQValue?
            switch jv_get_kind(next) {
            case JV_KIND_ARRAY, JV_KIND_OBJECT:
                guard frames.count < maximumDepth else {
                    jv_free(next)
                    return nil
                }
                frames.append(Reader(next))
            case JV_KIND_NULL: finished = .null
            case JV_KIND_FALSE: finished = .bool(false)
            case JV_KIND_TRUE: finished = .bool(true)
            case JV_KIND_NUMBER: finished = .number(number(of: next))
            case JV_KIND_STRING: finished = .string(string(of: next))
            default: finished = .null
            }
            if finished != nil {
                jv_free(next)
            }
            while true {
                if let value = finished {
                    guard let top = frames.indices.last else {
                        return value
                    }
                    frames[top].add(value)
                    finished = nil
                }
                guard let top = frames.indices.last else {
                    return nil
                }
                if let child = frames[top].nextChild() {
                    next = child
                    break
                }
                let frame = frames.removeLast()
                jv_free(frame.source)
                finished = frame.value
            }
        }
    }

    /// The number in a jv it borrows, with jq's literal when it kept one.
    static func number(of value: jv) -> JQNumber {
        let double = jv_number_value(value)
        guard jv_number_has_literal(value) != 0, let literal = jv_number_get_literal(value) else {
            return JQNumber(literal: nil, doubleValue: double)
        }
        return JQNumber(literal: String(cString: literal), doubleValue: double)
    }

    /// The text of a jv string it borrows.
    static func string(of value: jv) -> String {
        let count = Int(jv_string_length_bytes(jv_copy(value)))
        guard let base = jv_string_value(value), count > 0 else {
            return ""
        }
        return String(decoding: UnsafeRawBufferPointer(start: base, count: count), as: UTF8.self)
    }

    /// jq's JSON text for a jv it consumes.
    static func dump(_ value: jv, flags: Int32) -> String {
        let text = jv_dump_string(value, flags)
        defer { jv_free(text) }
        return string(of: text)
    }

    /// jq's JSON text for a jv it consumes, as UTF-8 data.
    static func dumpData(_ value: jv, flags: Int32) -> Data {
        let text = jv_dump_string(value, flags)
        defer { jv_free(text) }
        let count = Int(jv_string_length_bytes(jv_copy(text)))
        guard let base = jv_string_value(text), count > 0 else {
            return Data()
        }
        return Data(bytes: base, count: count)
    }

    /// An error message it consumes: the text of a string, otherwise the value as JSON with
    /// the note the jq command adds.
    static func message(_ value: jv) -> String {
        guard jv_get_kind(value) == JV_KIND_STRING else {
            return "(not a string): " + dump(value, flags: 0)
        }
        defer { jv_free(value) }
        return string(of: value)
    }
}

/// An array or object being built from a `JQValue`; owns `container`.
private struct Builder {
    private(set) var container: jv
    private var elements: ArraySlice<JQValue> = []
    private var members: JQObject = [:]
    private var keys: ArraySlice<String> = []
    private var key: String?

    init(_ elements: [JQValue]) {
        container = jv_array_sized(Int32(clamping: elements.count))
        self.elements = elements[...]
    }

    init(_ members: JQObject) {
        container = jv_object()
        self.members = members
        keys = members.keys[...]
    }

    /// The next member to convert, if any.
    mutating func nextChild() -> JQValue? {
        if let element = elements.popFirst() {
            return element
        }
        while let key = keys.popFirst() {
            if let member = members[key] {
                self.key = key
                return member
            }
        }
        return nil
    }

    /// Adds the converted child, which it consumes.
    mutating func add(_ child: jv) {
        if let key {
            container = jv_object_set(container, JV.make(key), child)
        } else {
            container = jv_array_append(container, child)
        }
    }
}

/// An array or object being read into a `JQValue`; owns a reference to `source`.
private struct Reader {
    let source: jv
    private let isObject: Bool
    private var position: Int32
    private let count: Int32
    private var key = ""
    private var elements: [JQValue] = []
    private var members = JQObject()

    init(_ source: jv) {
        self.source = source
        isObject = jv_get_kind(source) == JV_KIND_OBJECT
        if isObject {
            position = jv_object_iter(source)
            count = 0
        } else {
            position = 0
            count = jv_array_length(jv_copy(source))
            elements.reserveCapacity(Int(count))
        }
    }

    /// The next member, which the caller owns, if any.
    mutating func nextChild() -> jv? {
        if isObject {
            guard jv_object_iter_valid(source, position) != 0 else {
                return nil
            }
            let key = jv_object_iter_key(source, position)
            self.key = JV.string(of: key)
            jv_free(key)
            let member = jv_object_iter_value(source, position)
            position = jv_object_iter_next(source, position)
            return member
        }
        guard position < count else {
            return nil
        }
        position += 1
        return jv_array_get(jv_copy(source), position - 1)
    }

    mutating func add(_ child: JQValue) {
        if isObject {
            members[key] = child
        } else {
            elements.append(child)
        }
    }

    var value: JQValue {
        isObject ? .object(members) : .array(elements)
    }
}

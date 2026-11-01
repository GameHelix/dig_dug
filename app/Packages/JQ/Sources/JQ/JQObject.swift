/// A JSON object whose keys keep their order, as jq keeps and prints them.
///
/// Equality ignores the order, as in jq: `{"a":1,"b":2}` equals `{"b":2,"a":1}`.
public struct JQObject: Sendable, Hashable {
    /// The keys, in order.
    public private(set) var keys: [String] = []
    private var values: [String: JQValue] = [:]

    public init() {}

    /// An object with these members in order. A repeated key keeps its first place and its
    /// last value, as when jq parses `{"a":1,"a":2}`.
    public init(_ members: some Sequence<(String, JQValue)>) {
        for (key, value) in members {
            self[key] = value
        }
    }

    public var count: Int {
        keys.count
    }

    public var isEmpty: Bool {
        keys.isEmpty
    }

    /// The value for a key. Setting a new key appends it; setting nil removes the key.
    public subscript(key: String) -> JQValue? {
        get {
            values[key]
        }
        set {
            if let newValue {
                if values.updateValue(newValue, forKey: key) == nil {
                    keys.append(key)
                }
            } else if values.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public static func == (lhs: JQObject, rhs: JQObject) -> Bool {
        lhs.values == rhs.values
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(values)
    }
}

extension JQObject: Sequence {
    public typealias Element = (key: String, value: JQValue)

    /// The members in key order.
    public func makeIterator() -> some IteratorProtocol<Element> {
        let values = values
        return keys.lazy.compactMap { key in values[key].map { (key: key, value: $0) } }.makeIterator()
    }

    public var underestimatedCount: Int {
        keys.count
    }
}

extension JQObject: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JQValue)...) {
        self.init(elements)
    }
}

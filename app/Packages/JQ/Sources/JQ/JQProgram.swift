import CJQ
import Synchronization

/// A jq program, compiled once and run in process.
///
/// A jq state is not thread-safe, so runs of one program take turns behind a lock; separate
/// programs have separate states and run in parallel.
public final class JQProgram: Sendable {
    /// The program's text.
    public let source: String

    private let state: Mutex<CompiledState>

    /// Compiles `source`, or throws jq's compile errors.
    public init(_ source: String) throws(JQError) {
        let compiled = try CompiledState(source)
        self.source = source
        state = Mutex(compiled)
    }

    /// Runs the program on `input` and returns its outputs in order. Throws jq's message
    /// when the program raises an error it does not catch.
    public func run(_ input: JQValue) throws(JQError) -> [JQValue] {
        let value = JV.make(input)
        return try state.withLock { (compiled: inout CompiledState) throws(JQError) -> [JQValue] in
            try compiled.run(value)
        }
    }
}

/// One jq state with a compiled program; freed with the state.
private struct CompiledState: ~Copyable {
    private let jq: OpaquePointer

    init(_ source: String) throws(JQError) {
        Oniguruma.prepare()
        guard let jq = jq_init() else {
            throw .compile("jq: error: out of memory")
        }
        let diagnostics = Diagnostics()
        jq_set_error_cb(jq, collectMessage, Unmanaged.passUnretained(diagnostics).toOpaque())
        let compiled = withExtendedLifetime(diagnostics) {
            source.withCString { jq_compile(jq, $0) }
        }
        // jq reports errors through this callback only while compiling.
        jq_set_error_cb(jq, discardMessage, nil)
        guard compiled != 0 else {
            var state: OpaquePointer? = jq
            jq_teardown(&state)
            throw .compile(diagnostics.messages.joined(separator: "\n"))
        }
        self.jq = jq
    }

    deinit {
        var state: OpaquePointer? = jq
        jq_teardown(&state)
    }

    /// Runs the program on an input it consumes, as the jq command does for each input.
    func run(_ input: jv) throws(JQError) -> [JQValue] {
        jq_start(jq, input, 0)
        var outputs: [JQValue] = []
        while true {
            let result = jq_next(jq)
            if jv_get_kind(result) != JV_KIND_INVALID {
                defer { jv_free(result) }
                guard let output = JV.value(of: result) else {
                    throw .runtime("Output exceeds depth limit (\(JV.maximumDepth) levels)")
                }
                outputs.append(output)
            } else if jq_halted(jq) != 0 {
                jv_free(result)
                try finishHalt()
                return outputs
            } else if jv_invalid_has_msg(jv_copy(result)) != 0 {
                throw .runtime(JV.message(jv_invalid_get_msg(result)))
            } else {
                jv_free(result)
                return outputs
            }
        }
    }

    /// `halt` ends the outputs; `halt_error` with a nonzero exit code is an error.
    private func finishHalt() throws(JQError) {
        let code = jq_get_exit_code(jq)
        let exitCode = switch jv_get_kind(code) {
        case JV_KIND_INVALID: 0
        case JV_KIND_NUMBER: Int(exactly: jv_number_value(code).rounded(.towardZero)) ?? 5
        default: 5
        }
        jv_free(code)
        let message = jq_get_error_message(jq)
        guard exitCode != 0 else {
            jv_free(message)
            return
        }
        var text = switch jv_get_kind(message) {
        case JV_KIND_STRING: JV.string(of: message)
        case JV_KIND_INVALID, JV_KIND_NULL: ""
        default: JV.dump(jv_copy(message), flags: 0)
        }
        jv_free(message)
        if text.hasSuffix("\n") {
            text.removeLast()
        }
        throw .runtime(text.isEmpty ? "The program stopped with exit code \(exitCode)" : text)
    }
}

/// Messages jq reports while compiling, formatted as the jq command prints them.
private final class Diagnostics {
    var messages: [String] = []
}

private func collectMessage(_ context: UnsafeMutableRawPointer?, _ message: jv) {
    let formatted = jq_format_error(message)
    defer { jv_free(formatted) }
    guard let context, jv_get_kind(formatted) == JV_KIND_STRING else {
        return
    }
    var text = JV.string(of: formatted)
    while text.hasSuffix("\n") {
        text.removeLast()
    }
    Unmanaged<Diagnostics>.fromOpaque(context).takeUnretainedValue().messages.append(text)
}

private func discardMessage(_ context: UnsafeMutableRawPointer?, _ message: jv) {
    jv_free(message)
}

/// Oniguruma sets up its encodings the first time a regex is compiled, without a lock. One
/// regex run here, once, before any program is compiled, finishes that before programs can
/// run in parallel.
private enum Oniguruma {
    static func prepare() {
        _ = prepared
    }

    private static let prepared: Bool = {
        guard let jq = jq_init() else {
            return false
        }
        var state: OpaquePointer? = jq
        defer { jq_teardown(&state) }
        jq_set_error_cb(jq, discardMessage, nil)
        guard jq_compile(jq, #""" | test("")"#) != 0 else {
            return false
        }
        jq_start(jq, jv_null(), 0)
        while true {
            let result = jq_next(jq)
            let done = jv_get_kind(result) == JV_KIND_INVALID
            jv_free(result)
            if done {
                return true
            }
        }
    }()
}

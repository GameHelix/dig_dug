import Foundation

/// The Go toolchain and the environment programs run with. Apps started from the Dock get a
/// minimal PATH that usually lacks Go and Homebrew, so the login shell (/bin/zsh, the macOS
/// default) is asked once; the usual install locations fill any gap.
public struct Toolchain: Sendable {
    /// The login shell's environment, PATH widened with the usual install locations.
    public var environment: [String: String]
    public var go: String?
    /// Like "go1.27.3".
    public var goVersion: String?

    public init(environment: [String: String], go: String? = nil, goVersion: String? = nil) {
        self.environment = environment
        self.go = go
        self.goVersion = goVersion
    }

    /// The go.mod language version for new lesson folders, like "1.27".
    public var languageVersion: String { Toolchain.languageVersion(goVersion ?? "") }

    public static func languageVersion(_ v: String) -> String {
        let parts = v.replacingOccurrences(of: "go", with: "").split(separator: ".")
        guard parts.count >= 2 else { return "1.22" }
        return "\(parts[0]).\(parts[1].prefix(while: \.isNumber))"
    }

    /// The usual places Go is installed.
    static func candidates(home: String) -> [String] {
        let sdk = ((try? FileManager.default.contentsOfDirectory(atPath: home + "/sdk")) ?? [])
            .filter { $0.hasPrefix("go") }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(home)/sdk/\($0)/bin/go" }
        return ["/opt/homebrew/bin/go", "/usr/local/go/bin/go", "/usr/local/bin/go", "/opt/local/bin/go",
                home + "/.goenv/shims/go", home + "/.asdf/shims/go", home + "/.local/share/mise/shims/go"] + sdk
    }

    /// Finds Go: the path set in Settings, else the login shell's PATH, else the usual install
    /// locations. Off the main thread; it runs the shell and `go env` (both with timeouts).
    public static func discover(goOverride: String?) async -> Toolchain {
        let home = NSHomeDirectory()
        var env = ProcessInfo.processInfo.environment
        var shellGo: String?
        let script = #"printf '\n__GW_BEGIN__\n'; command -v go || printf '\n'; printf '__GW_ENV__\n'; /usr/bin/env -0; printf '__GW_END__'"#
        // An interactive login shell reads .zprofile and .zshrc, where PATH is often set; a
        // plain login shell is the fallback if that fails or hangs.
        for flags in [["-i", "-l", "-c"], ["-l", "-c"]] {
            let out = await ProcessRunner.run(ProcessRequest(executable: SystemTools.zsh, arguments: flags + [script], directory: home,
                                                             environment: env, timeout: .seconds(8), outputLimit: 1 << 20))
            guard let begin = out.stdout.range(of: "\n__GW_BEGIN__\n"),
                  let mid = out.stdout.range(of: "__GW_ENV__\n", range: begin.upperBound..<out.stdout.endIndex),
                  let end = out.stdout.range(of: "__GW_END__", range: mid.upperBound..<out.stdout.endIndex) else { continue }
            let found = out.stdout[begin.upperBound..<mid.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if found.hasPrefix("/") { shellGo = found }
            var shellEnv: [String: String] = [:]
            for entry in out.stdout[mid.upperBound..<end.lowerBound].split(separator: "\0") {
                let kv = entry.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { shellEnv[kv[0]] = kv[1] }
            }
            if shellEnv["PATH"] != nil {
                for key in ["SHLVL", "_", "PWD", "OLDPWD", "TERM_SESSION_ID", "TERM", "PS1", "PROMPT"] { shellEnv.removeValue(forKey: key) }
                env = shellEnv
            }
            break
        }
        var dirs: [String] = []
        for d in (env["PATH"] ?? "").split(separator: ":").map(String.init) + [
            "/opt/homebrew/bin", "/usr/local/go/bin", "/usr/local/bin", home + "/go/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ] where !d.isEmpty && !dirs.contains(d) {
            dirs.append(d)
        }
        env["PATH"] = dirs.joined(separator: ":")
        env["HOME"] = env["HOME"] ?? home

        func runnable(_ p: String?) -> String? {
            guard let p, !p.isEmpty else { return nil }
            let path = (p as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
                  FileManager.default.isExecutableFile(atPath: path) else { return nil }
            return path
        }
        var t = Toolchain(environment: env)
        let candidates = [goOverride, shellGo] + dirs.map { $0 + "/go" } + Toolchain.candidates(home: home)
        for c in candidates {
            guard let go = runnable(c) else { continue }
            let out = await ProcessRunner.run(ProcessRequest(executable: go, arguments: ["env", "GOVERSION"], directory: home,
                                                             environment: env, timeout: .seconds(20)))
            let v = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if out.succeeded && v.hasPrefix("go") {
                t.go = go
                t.goVersion = v
                break
            }
        }
        return t
    }

    /// The environment for running Go: the go command's folder first on PATH, so tools it
    /// starts find the same Go, and nothing that would switch toolchains or modules modes.
    public func goEnvironment(submit: Bool) -> [String: String] {
        var env = environment
        env["GOTOOLCHAIN"] = "local"
        env["GOFLAGS"] = "-mod=mod"
        env["GOWORK"] = "off"
        env["GO111MODULE"] = "on"
        env["GOPHERWOOD_SUBMIT"] = submit ? "1" : "0"
        if let go {
            env["PATH"] = (go as NSString).deletingLastPathComponent + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        }
        return env
    }
}

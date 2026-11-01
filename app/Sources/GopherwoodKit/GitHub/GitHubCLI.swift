import Foundation

/// The GitHub CLI's sign-in to github.com, as gh reports it.
public enum GitHubSignIn: Sendable {
    case signedIn(GitHubToken)
    /// gh is there but not signed in to github.com.
    case notSignedIn
    /// gh isn't installed where the app looks.
    case noCLI
    /// gh did not answer in time.
    case failed(String)

    public var token: GitHubToken? {
        if case .signedIn(let token) = self { token } else { nil }
    }
}

/// The GitHub CLI, gh, which holds your GitHub sign-in. The app asks it for a token
/// (`gh auth token`) only when it checks GitHub, uses the token for that check and never
/// stores it.
public enum GitHubCLI {
    /// Where gh is: on the login shell's PATH (Toolchain.environment), else in /opt/homebrew/bin
    /// or /usr/local/bin.
    public static func locate(environment: [String: String]) -> String? {
        let dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        for dir in dirs where !dir.isEmpty {
            let path = (dir as NSString).appendingPathComponent("gh")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
               FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// The sign-in of the gh that `locate` finds.
    public static func signIn(environment: [String: String]) async -> GitHubSignIn {
        await signIn(gh: locate(environment: environment), environment: environment)
    }

    /// Runs `gh auth token --hostname github.com` through the process runner, with gh's prompts
    /// and update notices off. Its output never leaves this function except as a GitHubToken.
    static func signIn(gh: String?, environment: [String: String], timeout: Duration = .seconds(15)) async -> GitHubSignIn {
        guard let gh else { return .noCLI }
        var env = environment
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["NO_COLOR"] = "1"
        let out = await ProcessRunner.run(ProcessRequest(executable: gh, arguments: ["auth", "token", "--hostname", "github.com"],
                                                         directory: environment["HOME"] ?? NSHomeDirectory(), environment: env,
                                                         timeout: timeout, outputLimit: 64 << 10))
        if out.cancelled { return .failed("Stopped.") }
        if out.timedOut { return .failed("gh did not answer within \(timeout.components.seconds) seconds") }
        if let launch = out.launchError { return .failed("gh could not start: \(launch)") }
        guard out.succeeded else { return .notSignedIn }
        // One line: the token. Anything else is not one.
        let token = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.unicodeScalars.allSatisfy({ (0x21..<0x7F).contains($0.value) }) else { return .notSignedIn }
        return .signedIn(GitHubToken(token))
    }
}

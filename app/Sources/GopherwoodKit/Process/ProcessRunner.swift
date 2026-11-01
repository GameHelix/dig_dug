import Darwin
import Foundation
import os

/// Which processes `ProcessRunner.terminateAll` stops. Lesson programs (builds, runs,
/// command-line checks) are stopped when the app quits; git is not, because a killed git
/// leaves .git/index.lock behind and every later commit and pull fails.
public struct ProcessKind: Hashable, Sendable {
    public let name: String
    public init(_ name: String) { self.name = name }

    public static let lesson = ProcessKind("lesson")
    public static let git = ProcessKind("git")
}

/// One program to run: a resolved path, an argument array (never a shell string), an
/// explicit environment and working folder, and limits.
public struct ProcessRequest: Sendable {
    public var executable: String
    public var arguments: [String]
    public var directory: String
    public var environment: [String: String]
    public var timeout: Duration
    /// Bytes kept of the combined output, and of standard output on its own.
    public var outputLimit: Int
    /// After the process exits, how long to wait for programs it left behind to close the
    /// output pipes.
    public var waitDelay: Duration = .seconds(2)
    /// Stop whatever is left in the process group once the process exits.
    public var killGroupOnExit = false
    public var kind: ProcessKind = .lesson
    /// How a timeout or a cancellation stops the program: nil kills the process group at
    /// once (SIGKILL); a grace period sends SIGTERM first, so the program can clean up (git
    /// removes its lock file), and SIGKILL only if it is still running when the period ends.
    public var gracePeriod: Duration?

    public init(executable: String, arguments: [String], directory: String, environment: [String: String],
                timeout: Duration = .seconds(60), outputLimit: Int = 256 << 10, killGroupOnExit: Bool = false,
                kind: ProcessKind = .lesson, gracePeriod: Duration? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.environment = environment
        self.timeout = timeout
        self.outputLimit = outputLimit
        self.killGroupOnExit = killGroupOnExit
        self.kind = kind
        self.gracePeriod = gracePeriod
    }
}

/// What a finished process left behind.
public struct ProcessOutput: Sendable {
    /// Standard output and standard error, interleaved as they arrived.
    public var combined = ""
    public var stdout = ""
    public var stderr = ""
    /// The exit status; -1 if a signal ended the process, -2 if it never started.
    public var exitCode: Int32 = -2
    public var signal: Int32 = 0
    public var timedOut = false
    public var cancelled = false
    public var truncated = false
    public var launchError: String?
    public var duration: Duration = .zero

    public var succeeded: Bool { exitCode == 0 && !timedOut && !cancelled && launchError == nil }
}

/// Runs programs with posix_spawn. Each run starts in a process group of its own, so a
/// timeout or a cancelled task kills everything it started, and both output pipes are read
/// at once, so neither can fill up and stall the program.
public enum ProcessRunner {
    private static let running = OSAllocatedUnfairLock<[pid_t: ProcessKind]>(initialState: [:])

    /// Kills the process groups of one kind still running: lesson programs when the app
    /// quits. Git is never stopped this way; it gets SIGTERM and a grace period instead.
    public static func terminateAll(_ kind: ProcessKind = .lesson) {
        guard kind != .git else { return }
        for (pid, k) in running.withLock({ $0 }) where k == kind { kill(-pid, SIGKILL) }
    }

    /// Finds an executable: a path is taken as is, a bare name is looked up on the
    /// environment's PATH.
    public static func resolve(_ name: String, environment: [String: String]) -> String? {
        if name.contains("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        for dir in (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":") {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Runs the program; cancelling the task kills its process group.
    public static func run(_ request: ProcessRequest) async -> ProcessOutput {
        let flag = CancelFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ProcessOutput, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: runBlocking(request, cancel: flag))
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    /// Runs the program on the calling thread.
    public static func runBlocking(_ request: ProcessRequest, cancel: CancelFlag? = nil) -> ProcessOutput {
        let clock = ContinuousClock()
        let started = clock.now
        var result = execute(request, cancel: cancel, clock: clock, started: started)
        result.duration = clock.now - started
        return result
    }

    private static func execute(_ request: ProcessRequest, cancel: CancelFlag?, clock: ContinuousClock, started: ContinuousClock.Instant) -> ProcessOutput {
        var result = ProcessOutput()

        guard let executable = resolve(request.executable, environment: request.environment) else {
            result.launchError = "\(request.executable) was not found"
            return result
        }
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            result.launchError = String(cString: strerror(errno))
            return result
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        posix_spawn_file_actions_addchdir(&actions, request.directory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0) // a new group, led by the child
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for s in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGCHLD] { sigaddset(&defaults, s) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)

        var env = request.environment
        env["PWD"] = request.directory
        let argv = ([executable] + request.arguments).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        close(outPipe[1])
        close(errPipe[1])
        guard rc == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            result.launchError = "\(executable): \(String(cString: strerror(rc)))"
            return result
        }
        let child = pid, kind = request.kind
        running.withLock { $0[child] = kind }
        defer { running.withLock { _ = $0.removeValue(forKey: child) } }

        var combined = Data(), stdout = Data(), stderr = Data()
        let limit = request.outputLimit
        var fds = [pollfd(fd: outPipe[0], events: Int16(POLLIN), revents: 0),
                   pollfd(fd: errPipe[0], events: Int16(POLLIN), revents: 0)]
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        let deadline = started + request.timeout
        var exited = false
        var exitedAt: ContinuousClock.Instant?
        var status: Int32 = 0
        var dropped = false
        var terminatedAt: ContinuousClock.Instant?
        var killed = false

        func stopGroup(_ why: () -> Void) {
            why()
            if request.gracePeriod != nil {
                kill(-pid, SIGTERM)
                terminatedAt = clock.now
            } else {
                kill(-pid, SIGKILL)
                killed = true
            }
        }
        /// After SIGTERM, SIGKILL once the grace period is over.
        func escalate() {
            guard !killed, !exited, let at = terminatedAt, let grace = request.gracePeriod, clock.now - at >= grace else { return }
            kill(-pid, SIGKILL)
            killed = true
        }
        func reap() {
            guard !exited else { return }
            var s: Int32 = 0
            if waitpid(pid, &s, WNOHANG) == pid {
                exited = true
                exitedAt = clock.now
                status = s
                if request.killGroupOnExit { kill(-pid, SIGKILL) }
            }
        }
        func checkLimits() {
            guard !exited, !result.timedOut, !result.cancelled else { return }
            if clock.now >= deadline { stopGroup { result.timedOut = true } }
            if cancel?.isCancelled == true { stopGroup { result.cancelled = true } }
        }

        while fds.contains(where: { $0.fd >= 0 }) {
            reap()
            checkLimits()
            escalate()
            if let at = exitedAt, clock.now - at > request.waitDelay { break }
            let n = poll(&fds, nfds_t(fds.count), 50)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { continue }
            for i in fds.indices where fds[i].fd >= 0 && fds[i].revents != 0 {
                let r = read(fds[i].fd, &buffer, buffer.count)
                if r > 0 {
                    let chunk = buffer[0..<r]
                    if combined.count + r > limit { dropped = true }
                    if combined.count < limit { combined.append(contentsOf: chunk.prefix(limit - combined.count)) }
                    if i == 0 {
                        if stdout.count < limit { stdout.append(contentsOf: chunk.prefix(limit - stdout.count)) }
                    } else if stderr.count < limit {
                        stderr.append(contentsOf: chunk.prefix(limit - stderr.count))
                    }
                } else if r == 0 || (errno != EINTR && errno != EAGAIN) {
                    close(fds[i].fd)
                    fds[i].fd = -1
                }
            }
        }
        for f in fds where f.fd >= 0 { close(f.fd) }

        // Wait for the exit itself, still honouring the deadline and cancellation.
        while !exited {
            reap()
            if exited { break }
            checkLimits()
            escalate()
            usleep(10_000)
        }

        let low = status & 0x7f
        if low == 0 {
            result.exitCode = (status >> 8) & 0xff
        } else {
            result.exitCode = -1
            result.signal = low
        }
        result.truncated = dropped
        result.combined = String(decoding: combined, as: UTF8.self)
        result.stdout = String(decoding: stdout, as: UTF8.self)
        result.stderr = String(decoding: stderr, as: UTF8.self)
        return result
    }
}

/// Set from a task's cancellation handler; read by the loop that watches the process.
public final class CancelFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    public init() {}
    public func cancel() { state.withLock { $0 = true } }
    public var isCancelled: Bool { state.withLock { $0 } }
}

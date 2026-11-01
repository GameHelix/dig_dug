import Foundation

// What each kind of lesson holds besides its readme, as read from the per-type tables of
// db/schema.sql (version 3). Lists keep the tables' position order.

/// A lesson's content: one case per lesson type, built from that type's tables.
public enum LessonContent: Sendable {
    case code(CodeExercise)
    case codeTests(CodeExercise)
    case choice(Quiz)
    case cli(CLILesson)
    case githubChecks(GitHubChecks)
    case interviewChat(Interview)
}

/// A file of a code lesson as the lesson ships it.
public struct StarterFile: Hashable, Sendable {
    public let name: String
    public let content: String
    public let isHidden: Bool
    public let isReadonly: Bool

    public init(name: String, content: String, isHidden: Bool = false, isReadonly: Bool = false) {
        self.name = name
        self.content = content
        self.isHidden = isHidden
        self.isReadonly = isReadonly
    }

    /// Shown in the editor; hidden files never are.
    public var isVisible: Bool { !isHidden }
    /// Yours to edit: visible and not read-only.
}

/// type_code (checked by what the program prints) and type_code_tests (checked by its tests).
public struct CodeExercise: Sendable {
    public let progLang: String
    public let starterFiles: [StarterFile]
    /// What the program must print; set for type_code only.
    public let expectedOutput: String?

    /// Whether the app can run the code: it runs Go with your toolchain.
    public var runsHere: Bool { progLang == "go" }

    /// What the console says about a lesson in another language.
    public var otherLanguageNote: String { "This lesson uses \(progLang); Gopherwood runs Go lessons." }

    public init(progLang: String = "go", starterFiles: [StarterFile], expectedOutput: String? = nil) {
        self.progLang = progLang
        self.starterFiles = starterFiles
        self.expectedOutput = expectedOutput
    }

    public var visibleFiles: [StarterFile] { starterFiles.filter(\.isVisible) }
}

/// type_choice.
public struct Quiz: Sendable {
    public struct Question: Hashable, Sendable {
        public let question: String
        public let answers: [String]
        /// The one right answer.
        public let answer: String

        public init(question: String, answers: [String], answer: String) {
            self.question = question
            self.answers = answers
            self.answer = answer
        }

        /// Checked on this Mac: the chosen text must be the right answer.
        public func isCorrect(_ choice: String) -> Bool { choice == answer }
    }

    public let questions: [Question]

    public init(questions: [Question]) { self.questions = questions }
}

/// type_github_checks: checks about your GitHub repository. The app does not reach GitHub, so they are
/// listed, and you mark the lesson done yourself.
public struct GitHubChecks: Sendable {
    public struct Step: Hashable, Sendable {
        public let kind: String
        public let summary: String

        public init(kind: String, summary: String) {
            self.kind = kind
            self.summary = summary
        }
    }

    public let steps: [Step]

    public init(steps: [Step]) { self.steps = steps }
}

/// type_interview_chat: a question to answer in your own words.
public struct Interview: Sendable {
    public let studentPrompt: String
    /// What a good answer covers; nil when the lesson gives none.
    public let acceptanceCriteria: String?

    public init(studentPrompt: String, acceptanceCriteria: String?) {
        self.studentPrompt = studentPrompt
        self.acceptanceCriteria = acceptanceCriteria
    }
}

// MARK: - Command-line lessons

/// type_cli: steps that run a shell command or make an HTTP request, then check the result.
/// Values a step captures are used by later steps as ${name}.
public struct CLILesson: Sendable {
    /// The address of your server the lesson suggests, such as http://localhost:8080.
    public var baseURLDefault: String?
    /// The lesson needs the address of your own server, such as an app you deployed, and
    /// suggests none: the course's project.base_url.
    public var asksForBaseURL: Bool
    public var steps: [CLIStep]

    public init(baseURLDefault: String? = nil, asksForBaseURL: Bool = false, steps: [CLIStep]) {
        self.baseURLDefault = baseURLDefault
        self.asksForBaseURL = asksForBaseURL
        self.steps = steps
    }

    /// The suggested address, if there is one.
    public var defaultBaseURL: String? {
        guard !asksForBaseURL, let d = baseURLDefault?.trimmingCharacters(in: .whitespaces), !d.isEmpty else { return nil }
        return d
    }

    /// Whether any step calls a server or names ${baseURL}.
    public var usesBaseURL: Bool {
        steps.contains { step in
            switch step.action {
            case .http: true
            case .command(let c): c.command.contains("${baseURL}")
            }
        }
    }

    /// Whether any step runs a shell command, which needs a folder to run in.
    public var hasCommands: Bool {
        steps.contains { if case .command = $0.action { true } else { false } }
    }
}

public struct CLIStep: Sendable {
    public enum Action: Sendable {
        case command(CLICommand)
        case http(HTTPStep)
    }

    public var description: String
    /// How long to wait after the step, as the lesson asks (for a server to catch up).
    public var sleepAfterMs: Int?
    public var action: Action

    public init(description: String, sleepAfterMs: Int? = nil, action: Action) {
        self.description = description
        self.sleepAfterMs = sleepAfterMs
        self.action = action
    }

    /// What the step does, before ${variables} are filled in: the command, or "GET url".
    public var actionText: String {
        switch action {
        case .command(let c): c.command
        case .http(let h): "\(h.method) \(h.fullURL)"
        }
    }

    /// The names this step captures for later steps.
    public var captureNames: [String] {
        switch action {
        case .command(let c): c.variables.map(\.name)
        case .http(let h): h.bodyVariables.map(\.name) + h.headerVariables.map(\.name)
        }
    }
}

public struct NameValue: Hashable, Sendable {
    public var name: String
    public var value: String
    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

public struct CLICommand: Sendable {
    public var command: String
    /// Keep only the block of output that starts with this text (stdout_filter_tmdl).
    public var stdoutFilterTmdl: String?
    /// Values to capture: the first group of each regex over the output.
    public var variables: [NameValue]
    public var tests: [CommandTest]

    public init(command: String, stdoutFilterTmdl: String? = nil, variables: [NameValue] = [], tests: [CommandTest] = []) {
        self.command = command
        self.stdoutFilterTmdl = stdoutFilterTmdl
        self.variables = variables
        self.tests = tests
    }
}

/// A value a check compares with.
public enum TypedValue: Hashable, Sendable {
    case bool(Bool)
    case int(Int)
    case string(String)
}

public struct JqExpectation: Hashable, Sendable {
    /// ==, !=, >, >=, < or <=.
    public var op: String
    public var value: TypedValue
    public init(_ op: String, _ value: TypedValue) {
        self.op = op
        self.value = value
    }
}

public enum CommandTest: Sendable {
    case exitCode(Int)
    case stdoutContainsAll([String])
    case stdoutContainsNone([String])
    case stdoutLinesGT(Int)
    /// `jsonl`: standard output holds one JSON value per line, queried as an array.
    case stdoutJq(query: String, jsonl: Bool, expected: [JqExpectation])
}

public struct HTTPStep: Sendable {
    public enum Body: Sendable {
        /// The JSON body as the lesson sends it; ${names} inside its strings are filled in.
        case json(String)
        case form([NameValue])
    }

    public struct BodyVariable: Hashable, Sendable {
        public var name: String
        public var jsonPath: String?
        public var regex: String?
        public init(name: String, jsonPath: String? = nil, regex: String? = nil) {
            self.name = name
            self.jsonPath = jsonPath
            self.regex = regex
        }
    }

    public struct HeaderVariable: Hashable, Sendable {
        public var name: String
        public var header: String
        public var regex: String?
        public init(name: String, header: String, regex: String? = nil) {
            self.name = name
            self.header = header
            self.regex = regex
        }
    }

    public var method: String
    public var fullURL: String
    public var followRedirects: Bool
    public var basicAuth: NameValue?
    public var body: Body?
    public var headers: [NameValue]
    public var bodyVariables: [BodyVariable]
    public var headerVariables: [HeaderVariable]
    public var tests: [HTTPTest]

    public init(method: String = "GET", fullURL: String, followRedirects: Bool = true, basicAuth: NameValue? = nil,
                body: Body? = nil, headers: [NameValue] = [], bodyVariables: [BodyVariable] = [],
                headerVariables: [HeaderVariable] = [], tests: [HTTPTest] = []) {
        self.method = method
        self.fullURL = fullURL
        self.followRedirects = followRedirects
        self.basicAuth = basicAuth
        self.body = body
        self.headers = headers
        self.bodyVariables = bodyVariables
        self.headerVariables = headerVariables
        self.tests = tests
    }
}

public enum HTTPTest: Sendable {
    case statusCode(Int)
    case bodyContains(String)
    case bodyContainsNone(String)
    case headersContain(String, String)
    case headersEqual(String, String)
    case trailersContain(String, String)
    case trailersEqual(String, String)
    /// op: eq, ne, gt, gte, lt, lte, contains or not_contains.
    case jsonValue(path: String, op: String, value: TypedValue)
}

/// What a command-line lesson's ${baseURL} stands for:
/// - a lesson that asks for your own server uses the course's project.base_url, and has none
///   until you give it;
/// - a lesson that suggests an address uses your address for it (server_address) if you set
///   one, else the suggestion;
/// - any other lesson has no ${baseURL}.
public enum BaseURL: Equatable, Sendable {
    case yourServer(String?)
    case suggested(String, yours: String?)
    case none

    public init(lesson: CLILesson, projectBaseURL: String?, serverAddress: String?) {
        func clean(_ s: String?) -> String? { s.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 } }
        if lesson.asksForBaseURL {
            self = .yourServer(clean(projectBaseURL))
        } else if let suggested = lesson.defaultBaseURL {
            self = .suggested(suggested, yours: clean(serverAddress).flatMap { $0 == suggested ? nil : $0 })
        } else {
            self = .none
        }
    }

    /// The address the steps use, if there is one.
    public var url: String? {
        switch self {
        case .yourServer(let url): url
        case .suggested(let suggested, let yours): yours ?? suggested
        case .none: nil
        }
    }

    /// A lesson that asks for your server's address and does not have it yet.
    public var isMissing: Bool { self == .yourServer(nil) }
}

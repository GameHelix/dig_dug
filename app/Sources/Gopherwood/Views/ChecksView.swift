import AppKit
import GopherwoodKit
import SwiftUI

/// A command-line lesson: where it runs, then its steps as a pipeline.
struct ChecksLessonView: View {
    let lesson: LessonModel
    let session: ChecksSession

    var body: some View {
        ReadmeColumn(lesson: lesson) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Checks")
                    .font(.system(size: Theme.headingSize(2), weight: .semibold))
                if session.needsFolder || session.baseURL != .none {
                    ProjectSettings(session: session)
                }
                if let error = session.runError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Pipeline(session: session)
                ChecksFooter(session: session)
            }
        }
    }
}

struct ProjectSettings: View {
    @Bindable var session: ChecksSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.needsFolder {
                HStack(spacing: 10) {
                    Label("Project folder", systemImage: "folder")
                        .frame(width: 140, alignment: .leading)
                    Text(session.projectDir.isEmpty ? "Not chosen yet" : (session.projectDir as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(session.projectDir.isEmpty ? Theme.secondaryText : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") { session.chooseFolder() }
                        .secondaryGlassButton()
                    if !session.projectDir.isEmpty {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.projectDir)])
                        } label: {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .secondaryGlassButton()
                        .help("Show in Finder")
                        .accessibilityLabel("Show the project folder in Finder")
                    }
                }
            }
            switch session.baseURL {
            case .yourServer(let url):
                HStack(spacing: 10) {
                    Label("Your server", systemImage: "network")
                        .frame(width: 140, alignment: .leading)
                    // Verbatim, or Text reads the address as a link and colors it.
                    TextField("Your server", text: $session.addressField, prompt: Text(verbatim: "https://your-app.example.com"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .onSubmit { session.commitAddress() }
                        .accessibilityLabel("Your server's address")
                }
                if url == nil {
                    Label("This lesson checks a server you deployed. Enter its address; the other lessons of \(session.lesson.courseTitle) that ask for it use it too.",
                          systemImage: "exclamationmark.circle")
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .suggested(let suggested, _):
                HStack(spacing: 10) {
                    Label("Server address", systemImage: "network")
                        .frame(width: 140, alignment: .leading)
                    TextField("Server address", text: $session.addressField, prompt: Text(verbatim: suggested))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .onSubmit { session.commitAddress() }
                        .accessibilityLabel("Server address")
                    if session.replacedSuggestion != nil {
                        Button("Use Suggested") { session.useSuggestedAddress() }
                            .secondaryGlassButton()
                            .help("Go back to \(suggested), for every lesson that suggests it")
                    }
                }
                if session.replacedSuggestion != nil {
                    Text("Every lesson that suggests \(suggested) uses your address.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
            case .none:
                EmptyView()
            }
        }
        .font(.system(size: 13))
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct Pipeline: View {
    let session: ChecksSession

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(session.cli.steps.enumerated()), id: \.offset) { i, step in
                    StepRow(index: i, step: step, state: session.states[i], result: session.results[i])
                }
            }
        }
    }
}

struct StepRow: View {
    let index: Int
    let step: CLIStep
    let state: ChecksSession.StepState
    let result: StepResult?
    @ViewState private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A finished step opens to show its tests and output; a pending one has nothing
            // to show yet, so its title is plain text rather than a button that does nothing.
            if result != nil {
                Button {
                    withAnimation(reduceMotion ? nil : .snappy) { expanded.toggle() }
                } label: {
                    titleLine
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Step \(index + 1): \(step.description), \(stateText)")
                .accessibilityHint(expanded ? "Hides the step's results" : "Shows the step's results")
            } else {
                titleLine
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Step \(index + 1): \(step.description), \(stateText)")
            }
            CommandText(text: result?.action ?? step.actionText)
                .padding(.leading, 28)
            if expanded, let result {
                StepDetail(result: result)
                    .padding(.leading, 28)
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onChange(of: state) { _, s in if s == .failed { expanded = true } }
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StepStateIcon(state: state)
                .frame(width: 18)
            Text(step.description.isEmpty ? "Step \(index + 1)" : step.description)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if result != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
        .contentShape(Rectangle())
    }

    private var stateText: String {
        switch state {
        case .pending: "pending"
        case .running: "running"
        case .passed: "passed"
        case .failed: "failed"
        }
    }
}

/// A step's command or request: up to three lines, then "Show all (N lines)", so steps that
/// start alike can still be told apart and a long script does not fill the pipeline.
struct CommandText: View {
    let text: String
    static let shownLines = 3
    @ViewState private var showAll = false

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let long = lines.count > Self.shownLines
        // One very long line wraps instead; past six wrapped lines it is cut in the middle.
        let wide = !long && text.count > 320
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: long && !showAll ? lines.prefix(Self.shownLines).joined(separator: "\n") : text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.78))
                .lineLimit(showAll ? nil : 6)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if long || wide {
                Button(showAll ? "Show less" : long ? "Show all (\(lines.count) lines)" : "Show all") {
                    showAll.toggle()
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
        }
    }
}

struct StepStateIcon: View {
    let state: ChecksSession.StepState

    var body: some View {
        // One image that changes, so the bounce plays when the step passes; while the step
        // runs it is the turning spinner symbol.
        let running = state == .running
        Image(systemName: symbol)
            .symbolRenderingMode(running ? .hierarchical : nil)
            .foregroundStyle(color)
            .contentTransition(.symbolEffect(.replace))
            .runningSymbolEffect(running)
            .symbolEffect(.bounce, value: state == .passed)
            // The step's label already says pending, running, passed or failed.
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch state {
        case .pending: "circle.dashed"
        case .running: "progress.indicator"
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private var color: AnyShapeStyle {
        switch state {
        case .pending: AnyShapeStyle(.secondary)
        case .running: AnyShapeStyle(.primary)
        case .passed: AnyShapeStyle(Theme.success)
        case .failed: AnyShapeStyle(Theme.failure)
        }
    }
}

/// A finished step: its tests, then the output or the response.
struct StepDetail: View {
    let result: StepResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = result.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(result.checks.enumerated()), id: \.offset) { _, check in
                Label {
                    Text(check.text).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: check.state == .passed ? "checkmark" : "xmark")
                        .foregroundStyle(check.state == .passed ? Theme.success : Theme.failure)
                }
                .font(.system(size: 12.5))
            }
            // Made once when the step finished, off the main actor; long text is cut with Show All.
            if !result.shown.isEmpty {
                ScrollView(.vertical) {
                    LongText(text: result.shown)
                        .padding(10)
                }
                .frame(maxHeight: 260)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

struct ChecksFooter: View {
    let session: ChecksSession
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 12) {
            // One icon that stays and changes, so its bounce plays when the checks pass.
            Image(systemName: symbol)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: session.successCount)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(color)
            Spacer()
            if session.isRunning {
                Button("Stop", systemImage: "stop.fill") { session.stop() }
                    .secondaryGlassButton()
            } else {
                Button("Run Checks", systemImage: "play.fill") { session.runAll() }
                    .prominentGlassButton()
                    .help("Run Checks (⌘R)")
            }
        }
        .font(.system(size: 13, weight: .medium))
    }

    private var symbol: String {
        switch session.lastStatus {
        case .passed?: "checkmark.seal.fill"
        case .failed?: "xmark.octagon.fill"
        case .error?: "exclamationmark.triangle.fill"
        case .cancelled?: "stop.circle"
        case nil: "terminal"
        }
    }

    private var text: String {
        let took = session.lastDuration.map { " in \($0.shortText)" } ?? ""
        return switch session.lastStatus {
        case .passed?: "All checks passed" + took
        case .failed?: "Some checks failed" + took
        case .error?: "The checks could not run"
        case .cancelled?: "Stopped"
        case nil: "The checks run on this Mac, in your project folder."
        }
    }

    private var color: AnyShapeStyle {
        switch session.lastStatus {
        case .passed?: AnyShapeStyle(Theme.success)
        case .failed?: AnyShapeStyle(Theme.failure)
        case .error?: AnyShapeStyle(Theme.warning)
        case .cancelled?, nil: AnyShapeStyle(Theme.secondaryText)
        }
    }
}

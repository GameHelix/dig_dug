import GopherwoodKit
import SwiftUI

/// A GitHub lesson: the readme, your repository, and the steps the checks look for on GitHub.
struct GitHubLessonView: View {
    let lesson: LessonModel
    let session: GitHubSession

    var body: some View {
        ReadmeColumn(lesson: lesson) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Checks")
                    .font(.system(size: Theme.headingSize(2), weight: .semibold))
                RepositoryRow(session: session)
                if let error = session.runError {
                    Label {
                        Text(CodeSpans.attributed(error)).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 13))
                }
                GitHubSteps(session: session)
                GitHubFooter(lesson: lesson, session: session)
            }
        }
    }
}

/// "Your repository: owner/name" with Change…, or the field to enter it.
struct RepositoryRow: View {
    @Bindable var session: GitHubSession
    @FocusState private var fieldFocused: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let repo = session.repo, !session.isChangingRepo {
                HStack(spacing: 10) {
                    Image(systemName: "shippingbox")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Your repository: \(Text(verbatim: repo.fullName).font(.system(size: 13, design: .monospaced)))")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        openURL(repo.webURL)
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .secondaryGlassButton()
                    .help("Open \(repo.fullName) on GitHub")
                    .accessibilityLabel("Open your repository on GitHub")
                    Button("Change…") { session.changeRepo() }
                        .secondaryGlassButton()
                        .disabled(session.isRunning)
                }
            } else {
                HStack(spacing: 10) {
                    Label("Your repository", systemImage: "shippingbox")
                        .frame(width: 140, alignment: .leading)
                    // Verbatim, or Text reads the address as a link and colors it.
                    TextField("Your repository", text: $session.repoField, prompt: Text(verbatim: "owner/name or https://github.com/owner/name"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .focused($fieldFocused)
                        .onSubmit { session.commitRepo() }
                        .onExitCommand { session.cancelChange() }
                        .accessibilityLabel("Your repository on GitHub")
                    Button("Save") { session.commitRepo() }
                        .secondaryGlassButton()
                        .disabled(session.repoField.trimmingCharacters(in: .whitespaces).isEmpty)
                    if session.repo != nil {
                        Button("Cancel") { session.cancelChange() }
                            .secondaryGlassButton()
                    }
                }
                if let problem = session.repoProblem {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("The repository on GitHub you work in for \(session.lesson.courseTitle). Every GitHub lesson of the course checks it.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 13))
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onChange(of: session.focusRequests) { fieldFocused = true }
    }
}

struct GitHubSteps: View {
    let session: GitHubSession

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(session.checks.steps.enumerated()), id: \.offset) { i, step in
                    GitHubStepRow(index: i, step: step, state: session.states[i], result: session.results[i])
                }
            }
        }
    }
}

/// A step: its state, what it looks for and, once checked, why it passed or failed.
struct GitHubStepRow: View {
    let index: Int
    let step: GitHubChecks.Step
    let state: StepState
    let result: GitHubStepResult?
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StepStateIcon(state: state)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(step.summary)
                    .font(.system(size: 14, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let result {
                    Text(CodeSpans.attributed(result.reason))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let link = result?.link {
                Button {
                    openURL(link)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help("Open on GitHub")
                .accessibilityLabel("Open step \(index + 1) on GitHub")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(index + 1): \(step.summary), \(stateText)" + (result.map { ". \($0.reason)" } ?? ""))
    }

    private var stateText: String {
        switch state {
        case .pending: "pending"
        case .running: "checking"
        case .passed: "passed"
        case .failed: "failed"
        }
    }
}

/// How the checks went, Mark as Done for when GitHub can't be reached, and Check or Stop.
struct GitHubFooter: View {
    let lesson: LessonModel
    let session: GitHubSession
    @Environment(AppModel.self) private var app

    var body: some View {
        let done = app.isDone(lesson.detail.id)
        HStack(spacing: 12) {
            // One icon that stays and changes, so its bounce plays when the checks pass.
            Image(systemName: symbol(done: done))
                .contentTransition(.symbolEffect(.replace))
                .runningSymbolEffect(session.isRunning)
                .symbolEffect(.bounce, value: session.successCount)
                .foregroundStyle(color(done: done))
                .accessibilityHidden(true)
            Text(text(done: done))
                .foregroundStyle(color(done: done))
                .lineLimit(2)
            Spacer()
            if done {
                Button("Mark as Not Done") { app.setDone(lesson.detail.id, false) }
                    .secondaryGlassButton()
                    .help("Mark as not done (⇧⌘D)")
            } else {
                Button("Mark as Done") { lesson.markPassed() }
                    .secondaryGlassButton()
                    .help("Mark the lesson done without checking, for when GitHub can't be reached (⇧⌘D)")
            }
            if session.isRunning {
                Button("Stop", systemImage: "stop.fill") { session.stop() }
                    .secondaryGlassButton()
                    .help("Stop (⌘.)")
            } else {
                Button("Check", systemImage: "checkmark.seal") { lesson.submit() }
                    .prominentGlassButton()
                    .help("Check your repository on GitHub (⌘↩)")
            }
        }
        .font(.system(size: 13, weight: .medium))
    }

    private func symbol(done: Bool) -> String {
        if session.isRunning { return "progress.indicator" }
        switch session.lastStatus {
        case .passed?: return "checkmark.seal.fill"
        case .failed?: return "xmark.octagon.fill"
        case .error?: return "exclamationmark.triangle.fill"
        case .cancelled?: return "stop.circle"
        case nil: return done ? "checkmark.circle.fill" : "arrow.triangle.branch"
        }
    }

    private func text(done: Bool) -> String {
        if session.isRunning { return "Checking \(session.repo?.fullName ?? "your repository") on GitHub…" }
        let took = session.lastDuration.map { " in \($0.shortText)" } ?? ""
        return switch session.lastStatus {
        case .passed?: "All checks passed" + took
        case .failed?: "Some checks failed" + took
        case .error?: "The checks could not run"
        case .cancelled?: "Stopped"
        case nil: done ? "Done" : "The checks read your repository on GitHub."
        }
    }

    private func color(done: Bool) -> AnyShapeStyle {
        if session.isRunning { return AnyShapeStyle(.primary) }
        return switch session.lastStatus {
        case .passed?: AnyShapeStyle(Theme.success)
        case .failed?: AnyShapeStyle(Theme.failure)
        case .error?: AnyShapeStyle(Theme.warning)
        case .cancelled?: AnyShapeStyle(Theme.secondaryText)
        case nil: done ? AnyShapeStyle(.tint) : AnyShapeStyle(Theme.secondaryText)
        }
    }
}

/// Text with its `code` spans in monospace, such as "Sign in with `gh auth login` in Terminal".
enum CodeSpans {
    static func attributed(_ text: String) -> AttributedString {
        var out = AttributedString()
        for (i, part) in text.split(separator: "`", omittingEmptySubsequences: false).enumerated() {
            var piece = AttributedString(String(part))
            if i % 2 == 1 { piece.font = .system(size: 12, design: .monospaced) }
            out += piece
        }
        return out
    }
}

import AppKit
import GopherwoodKit
import SwiftUI

/// Settings › GitHub › Your solutions on GitHub: the repository passing Submits are committed
/// to, what waits to be pushed, and earlier solutions to add.
struct SolutionsSection: View {
    @Environment(AppModel.self) private var app
    @Binding var sheet: SolutionsModel.Sheet?

    var body: some View {
        @Bindable var solutions = app.solutions
        Section {
            if let repository = solutions.repository {
                LabeledContent("Repository") {
                    Link(repository.repo.fullName, destination: repository.repo.webURL)
                }
                LabeledContent("Folder") {
                    HStack {
                        Text((repository.folder.path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([repository.folder]) }
                    }
                }
                if let warning = solutions.branchWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Push after each passing Submit", isOn: $solutions.pushAfterSubmit)
                LabeledContent("Not pushed") {
                    HStack {
                        if solutions.isPushing { ProgressView().controlSize(.small) }
                        Text(solutions.unpushed.map { "\($0) commit\($0 == 1 ? "" : "s")" } ?? "…")
                            .monospacedDigit()
                        Button("Push Now") { solutions.push() }
                            .disabled(solutions.isPushing || (solutions.unpushed ?? 0) == 0)
                    }
                }
                if !solutions.earlier.isEmpty || solutions.isAddingEarlier {
                    LabeledContent("Earlier solutions") {
                        HStack {
                            if solutions.isAddingEarlier { ProgressView().controlSize(.small) }
                            Button("Add \(solutions.earlier.count) Earlier Solution\(solutions.earlier.count == 1 ? "" : "s")") { solutions.addEarlier() }
                                .disabled(solutions.isAddingEarlier)
                                .help("Lessons you finished before, with code you saved: each is committed on the day you finished it.")
                        }
                    }
                }
                if let problem = solutions.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let status = solutions.status {
                    Text(status).foregroundStyle(.secondary)
                }
                Button("Stop Using This Repository") { solutions.forget() }
                    .help("Gopherwood stops committing to it. The folder and the repository on GitHub stay as they are.")
            } else {
                Text("Each time a Submit passes, Gopherwood can commit your code to a repository of your own, dated that day, so your GitHub contribution graph shows your study.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Create Repository…") { sheet = .create }
                    Button("Use Existing Repository…") { sheet = .existing }
                }
            }
        } header: {
            Text("Your solutions on GitHub")
        } footer: {
            Text("Commits stay on this Mac until they are pushed, through the GitHub CLI's sign-in. These settings belong to this Mac, not to the library.")
        }
        .task(id: solutions.repository?.folder) { await solutions.refresh() }
    }
}

/// Create Repository…: a name, Public or Private, and a folder on this Mac.
struct CreateRepositorySheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = "go-solutions"
    @ViewState private var isPrivate = false
    /// Nil: ~/Documents/<name>.
    @ViewState private var chosenFolder: URL?
    @ViewState private var working = false
    @ViewState private var error: String?

    private var folder: URL { chosenFolder ?? SolutionsModel.defaultFolder(name) }

    var body: some View {
        let signedIn = if case .signedIn = app.githubAccount { true } else { false }
        let nameProblem = GitHubRepo.isName(name) ? nil : "A name is letters, digits, '.', '_' and '-'."
        let folderProblem = SolutionsRepository.problem(with: folder, outside: app.solutions.forbiddenFolders, mustBeEmpty: true)
        VStack(alignment: .leading, spacing: 14) {
            Text("Create a Repository for Your Solutions")
                .font(.system(size: Theme.headingSize(3), weight: .semibold))
            Form {
                TextField("Name", text: $name)
                    .font(.system(.body, design: .monospaced))
                Picker("Visibility", selection: $isPrivate) {
                    Text("Public").tag(false)
                    Text("Private").tag(true)
                }
                .pickerStyle(.segmented)
                Text("Contributions to a private repository show on your graph only if Private contributions is turned on in your GitHub profile.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                FolderRow(folder: folder) { chosenFolder = $0 }
            }
            .formStyle(.grouped)
            if let problem = error ?? nameProblem ?? folderProblem ?? accountProblem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if working || [.unknown, .checking].contains(app.githubAccount) { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    working = true
                    error = nil
                    Task {
                        error = await app.solutions.create(name: name, isPrivate: isPrivate, folder: folder)
                        working = false
                        if error == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || !signedIn || nameProblem != nil || folderProblem != nil)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    /// Why GitHub can't make the repository, as the GitHub CLI's sign-in stands: nil while it is
    /// being asked for, and the way to GitHub's own problem when it can't be reached.
    private var accountProblem: String? {
        switch app.githubAccount {
        case .signedIn, .unknown, .checking: nil
        case .notSignedIn: "Sign in with gh auth login in Terminal first: GitHub makes the repository on your account."
        case .noCLI: "Install the GitHub CLI (brew install gh) and sign in with gh auth login in Terminal first: GitHub makes the repository on your account."
        case .refused: "GitHub refused the GitHub CLI's sign-in: run gh auth login in Terminal again."
        case .failed(let why): why
        }
    }
}

/// Use Existing Repository…: owner/name or its address, and a folder on this Mac.
struct UseRepositorySheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @ViewState private var text = ""
    @ViewState private var chosenFolder: URL?
    @ViewState private var working = false
    @ViewState private var error: String?

    private var folder: URL { chosenFolder ?? SolutionsModel.defaultFolder(GitHubRepo(parsing: text)?.name ?? "go-solutions") }

    /// Which file will hold the table of solved lessons: known for a clone already here, else
    /// the rule, as the README is not here to read yet.
    private var tableLine: String {
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("README.md").path) else {
            return "The table of solved lessons goes in README.md, or in SOLUTIONS.md if the repository has a README of its own."
        }
        return SolutionsReadme.file(in: folder) == "README.md"
            ? "The table of solved lessons goes in README.md, which Gopherwood wrote."
            : "The table of solved lessons goes in SOLUTIONS.md: README.md is yours and stays as it is."
    }

    var body: some View {
        // A folder that can't be a clone (it has no .git) must be new or empty, as cloning needs:
        // said here, before you click. Whose clone one with .git is, git tells on the click.
        let maybeClone = FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path)
        let folderProblem = SolutionsRepository.problem(with: folder, outside: app.solutions.forbiddenFolders, mustBeEmpty: !maybeClone)
        VStack(alignment: .leading, spacing: 14) {
            Text("Use a Repository You Have")
                .font(.system(size: Theme.headingSize(3), weight: .semibold))
            Form {
                TextField("Repository", text: $text, prompt: Text(verbatim: "owner/name or https://github.com/owner/name"))
                    .font(.system(.body, design: .monospaced))
                FolderRow(folder: folder) { chosenFolder = $0 }
                Text("Gopherwood clones the repository into the folder, or uses the folder as it is when it already holds a clone of it. \(tableLine)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.grouped)
            if let problem = error ?? folderProblem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use Repository") {
                    working = true
                    error = nil
                    Task {
                        error = await app.solutions.useExisting(text, folder: folder)
                        working = false
                        if error == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || GitHubRepo(parsing: text) == nil || folderProblem != nil)
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}

/// The folder on this Mac, with Choose….
struct FolderRow: View {
    let folder: URL
    let choose: (URL) -> Void

    var body: some View {
        LabeledContent("Folder") {
            HStack {
                Text((folder.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.prompt = "Use Folder"
                    panel.message = "Choose the folder for your solutions repository"
                    panel.directoryURL = folder.deletingLastPathComponent()
                    if panel.runModal() == .OK, let url = panel.url { choose(url) }
                }
            }
        }
    }
}

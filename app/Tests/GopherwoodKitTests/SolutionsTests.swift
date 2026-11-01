import Foundation
import GRDB
import Testing
@testable import GopherwoodKit

/// The solutions repository in $TMPDIR, with a bare repository standing in for GitHub: git
/// rewrites origin's https address to it (url.<bare>.insteadOf), so nothing leaves this Mac.
struct SolutionsSandbox {
    let root: URL
    let folder: URL
    let remote: URL
    let repo = GitHubRepo(owner: "ada", name: "go-solutions")!
    /// No git identity of its own: user.name and user.email are unset. Git may use local paths
    /// only (GIT_ALLOW_PROTOCOL=file), so nothing here can reach github.com.
    let env: [String: String]
    /// A gh that gives git no credentials: git never asks it for a local remote, and the real
    /// gh never runs.
    let gh: String
    /// The same, with origin rewritten to the bare repository.
    var toRemote: [String: String] {
        env.merging(["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "url.\(remote.path).insteadOf",
                     "GIT_CONFIG_VALUE_0": SolutionsRepository.remote(repo)]) { _, new in new }
    }

    init() throws {
        root = try Fixtures.tempDir("solutions")
        folder = root.appendingPathComponent("go-solutions", isDirectory: true)
        remote = root.appendingPathComponent("remote.git", isDirectory: true)
        env = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_ALLOW_PROTOCOL": "file"]
        gh = root.appendingPathComponent("gh").path
        try "#!/bin/sh\nexit 1\n".write(toFile: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh)
        try git(root, "init", "-q", "--bare", "-b", "main", remote.path)
    }

    @discardableResult
    func git(_ dir: URL, _ args: String...) throws -> String {
        let out = ProcessRunner.runBlocking(ProcessRequest(executable: "/usr/bin/git", arguments: ["-C", dir.path] + args, directory: dir.path,
                                                           environment: env, timeout: .seconds(60)))
        guard out.succeeded else { throw SolutionsError.failed("git \(args.joined(separator: " ")): \(out.combined)") }
        return out.stdout
    }

    static let ada = SolutionsAuthor(name: "ada", email: "123+ada@users.noreply.github.com")

    static func place(_ title: String, chapter: Int = 0, lesson: Int, slug: String) -> SolutionPlace {
        SolutionPlace(lessonID: "lesson-\(slug)", lessonTitle: title, chapterTitle: "Variables", courseTitle: "Learn Go", courseSlug: "learn-golang",
                      chapterPosition: chapter, chapterSlug: "1-variables", lessonPosition: lesson, lessonSlug: slug)
    }

    /// Noon UTC: the same day in every time zone the tests run in.
    static func day(_ text: String) -> Date { Clock.date(text + "T12:00:00Z") ?? Date() }
}

@Suite(.serialized) struct SolutionsTests {
    @Test func aSolvedLessonIsCommittedWhereItBelongsWhenItWasSolved() async throws {
        let box = try SolutionsSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let solutions = try await SolutionsRepository.create(at: box.folder, repo: box.repo, environment: box.env)
        #expect(try box.git(box.folder, "remote", "get-url", "origin") == "https://github.com/ada/go-solutions.git\n")
        #expect(await solutions.unpushed() == 0)

        let basic = SolutionsSandbox.place("Basic Types", lesson: 2, slug: "3-basic-types")
        #expect(basic.path == "learn-golang/01-variables/03-basic-types")
        let solved = SolutionsSandbox.day("2026-10-30")
        let first = Solution(place: basic, files: [SolutionFile(name: "main.go", content: "package main\n")], date: solved)
        // Without an identity of git's own and without a GitHub account, there is no author.
        await #expect(throws: SolutionsError.noAuthor) { try await solutions.commit(first, index: [basic], author: nil) }
        // A commit that failed holds nothing: the lesson is still missing, as an earlier solution to add.
        #expect(await solutions.missing([first]) == [first])
        // Something you staged yourself stays out of the commit.
        try "mine\n".write(to: box.folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try box.git(box.folder, "add", "notes.txt")
        #expect(try await solutions.commit(first, index: [basic], author: SolutionsSandbox.ada) == .committed)

        let log = try box.git(box.folder, "log", "--format=%s|%an|%ae|%aI|%cI")
        let fields = log.trimmingCharacters(in: .newlines).split(separator: "|").map(String.init)
        #expect(fields.prefix(3) == ["Solve \"Basic Types\" (Learn Go)", "ada", "123+ada@users.noreply.github.com"])
        #expect(fields.suffix(2).compactMap { try? Date($0, strategy: .iso8601) } == [solved, solved]) // author and committer: the Submit
        #expect(try box.git(box.folder, "show", "--name-only", "--format=", "HEAD").split(separator: "\n").sorted()
            == ["README.md", "learn-golang/01-variables/03-basic-types/main.go"])
        #expect(try String(contentsOf: box.folder.appendingPathComponent("learn-golang/01-variables/03-basic-types/main.go"), encoding: .utf8) == "package main\n")
        let readme = try String(contentsOf: box.folder.appendingPathComponent("README.md"), encoding: .utf8)
        #expect(readme.hasPrefix(SolutionsReadme.marker + "\n# go-solutions\n") && readme.contains("## Learn Go\n"))
        #expect(readme.contains("| [Basic Types](learn-golang/01-variables/03-basic-types/) | Variables | 2026-10-30 |"))

        // The same code again: no commit.
        #expect(try await solutions.commit(Solution(place: basic, files: first.files, date: SolutionsSandbox.day("2026-10-31")), index: [basic], author: SolutionsSandbox.ada) == .unchanged)
        #expect(try box.git(box.folder, "rev-list", "--count", "HEAD") == "1\n")
        // New code: a commit, and the README keeps the day it was first solved.
        let changed = Solution(place: basic, files: [SolutionFile(name: "main.go", content: "package main\n\nfunc main() {}\n")], date: SolutionsSandbox.day("2026-10-31"))
        #expect(try await solutions.commit(changed, index: [basic], author: SolutionsSandbox.ada) == .committed)
        #expect(try String(contentsOf: box.folder.appendingPathComponent("README.md"), encoding: .utf8).contains("| Variables | 2026-10-30 |"))

        // Git's own identity wins when it has one.
        try box.git(box.folder, "config", "user.name", "Ada Lovelace")
        try box.git(box.folder, "config", "user.email", "ada@example.com")
        let other = Solution(place: SolutionsSandbox.place("Var", lesson: 1, slug: "2-var"), files: [SolutionFile(name: "main.go", content: "package main // var\n")],
                             date: SolutionsSandbox.day("2026-10-31"))
        #expect(try await solutions.commit(other, index: [basic, other.place], author: SolutionsSandbox.ada) == .committed)
        #expect(try box.git(box.folder, "log", "-1", "--format=%an <%ae>") == "Ada Lovelace <ada@example.com>\n")
        #expect(try box.git(box.folder, "status", "--porcelain", "--", "notes.txt") == "A  notes.txt\n") // still only staged
        #expect(await solutions.unpushed() == 3)
    }

    @Test func earlierSolutionsAreAddedOldestFirstOnTheirDays() async throws {
        let box = try SolutionsSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let solutions = try await SolutionsRepository.create(at: box.folder, repo: box.repo, environment: box.env)
        let places = [SolutionsSandbox.place("Run Code", lesson: 0, slug: "1-run-code"), SolutionsSandbox.place("Var", lesson: 1, slug: "2-var"),
                      SolutionsSandbox.place("Constants", chapter: 1, lesson: 0, slug: "1-constants")]
        let earlier = zip(places, ["2026-10-02", "2026-10-05", "2026-10-09"]).map {
            Solution(place: $0, files: [SolutionFile(name: "main.go", content: "package main // \($0.lessonTitle)\n")], date: SolutionsSandbox.day($1))
        }
        #expect(try await solutions.commit(earlier[1], index: places, author: SolutionsSandbox.ada) == .committed) // one is there already
        let missing = await solutions.missing(earlier)
        #expect(missing.map(\.place.lessonTitle) == ["Run Code", "Constants"])
        for solution in missing { _ = try await solutions.commit(solution, index: places, author: SolutionsSandbox.ada) }
        let log = try box.git(box.folder, "log", "--reverse", "--format=%aI %s").split(separator: "\n").map(String.init)
        #expect(log.map { String($0.split(separator: " ", maxSplits: 1)[1]) } == ["Solve \"Var\" (Learn Go)", "Solve \"Run Code\" (Learn Go)", "Solve \"Constants\" (Learn Go)"])
        #expect(log.compactMap { try? Date(String($0.prefix(while: { $0 != " " })), strategy: .iso8601) } == [earlier[1].date, earlier[0].date, earlier[2].date])
        let readme = try String(contentsOf: box.folder.appendingPathComponent("README.md"), encoding: .utf8)
        #expect(readme.contains("| [Run Code](learn-golang/01-variables/01-run-code/) | Variables | 2026-10-02 |"))
        #expect(readme.contains("| [Constants](learn-golang/02-variables/01-constants/) | Variables | 2026-10-09 |"))
        #expect(await solutions.missing(earlier).isEmpty)
    }

    @Test func theLibraryGivesDoneLessonsWithSavedCode() async throws {
        let (db, dir) = try Fixtures.database()
        defer { try? FileManager.default.removeItem(at: dir) }
        let places = try await db.solutionPlaces()
        #expect(places.map(\.lessonID) == [Fixtures.codeLesson, Fixtures.testsLesson])
        #expect(places[1].path == "learn-testing/01-basics/02-add")
        try await db.saveCode(lesson: Fixtures.testsLesson, files: [CodeFileRecord(name: "main.go", content: "package main // mine\n", updatedAt: Fixtures.ts)])
        try await db.saveCode(lesson: Fixtures.codeLesson, files: [CodeFileRecord(name: "main.go", content: "package main // hello\n", updatedAt: Fixtures.ts)])
        try await db.setDone(Fixtures.testsLesson, true, at: "2026-10-05T08:00:00Z")
        try await db.setDone(Fixtures.codeLesson, true, at: "2026-10-07T08:00:00Z")
        try await db.setDone(Fixtures.quizLesson, true, at: "2026-10-01T08:00:00Z") // not code
        let earlier = try await db.earlierSolutions()
        #expect(earlier.map(\.place.lessonID) == [Fixtures.testsLesson, Fixtures.codeLesson]) // oldest first
        #expect(earlier[0].date == Clock.date("2026-10-05T08:00:00Z"))
        // Your editable file only: not the read-only test or the hidden one.
        #expect(earlier[0].files == [SolutionFile(name: "main.go", content: "package main // mine\n")])
    }

    @Test func pushesThroughTheGitHubCLIAndKeepsWhatFailsForTheNextPush() async throws {
        let box = try SolutionsSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let solutions = try await SolutionsRepository.create(at: box.folder, repo: box.repo, environment: box.toRemote)
        let place = SolutionsSandbox.place("Run Code", lesson: 0, slug: "1-run-code")
        _ = try await solutions.commit(Solution(place: place, files: [SolutionFile(name: "main.go", content: "package main\n")], date: SolutionsSandbox.day("2026-10-02")),
                                       index: [place], author: SolutionsSandbox.ada)
        #expect(await solutions.unpushed() == 1)
        await #expect(throws: SolutionsError.noCLI) { try await solutions.push(gh: nil) }

        // A push that fails leaves the commit for the next one.
        let gone = box.root.appendingPathComponent("gone.git").path
        let broken = SolutionsRepository(folder: box.folder, repo: box.repo, environment: box.toRemote.merging(["GIT_CONFIG_KEY_0": "url.\(gone).insteadOf"]) { _, new in new })
        await #expect(throws: SolutionsError.self) { try await broken.push(gh: box.gh) }
        #expect(await solutions.unpushed() == 1)
        // Each push says how it went in a short line, failures too.
        func notice(_ repository: SolutionsRepository) async -> SolutionsNotice {
            do { return SolutionsNotice(pushing: box.repo, .success(try await repository.push(gh: box.gh))) } catch {
                return SolutionsNotice(pushing: box.repo, .failure(error))
            }
        }
        let failed = await notice(broken)
        #expect(failed.failed && failed.text.hasPrefix("ada/go-solutions not pushed: "), "\(failed.text)")

        // Origin's real address is out of reach: git refuses https here.
        let unrewritten = SolutionsRepository(folder: box.folder, repo: box.repo, environment: box.env)
        #expect(await unrewritten.pushesToGitHub())
        await #expect(throws: SolutionsError.self) { try await unrewritten.push(gh: box.gh) }

        #expect(await notice(solutions) == SolutionsNotice(text: "Pushed 1 commit to ada/go-solutions", failed: false))
        #expect(await solutions.unpushed() == 0)
        #expect(await notice(solutions) == SolutionsNotice(text: "Nothing to push to ada/go-solutions", failed: false))
        #expect(try box.git(box.remote, "log", "--format=%s", "main") == "Solve \"Run Code\" (Learn Go)\n")
        // Origin keeps the plain https address, and git's config holds no helper and no secret.
        let config = try String(contentsOf: box.folder.appendingPathComponent(".git/config"), encoding: .utf8)
        #expect(config.contains("url = https://github.com/ada/go-solutions.git") && !config.contains("credential") && !config.contains("@github.com"))
        #expect(SolutionsRepository.credentialOptions(gh: "/opt/homebrew/bin/gh")
            == ["-c", "credential.helper=", "-c", "credential.helper=!/opt/homebrew/bin/gh auth git-credential"])
        #expect(SolutionsRepository.credentialOptions(gh: "/Users/a b/bin/gh").last == "credential.helper=!'/Users/a b/bin/gh' auth git-credential")
    }

    @Test func anExistingRepositoryIsAdoptedOrCloned() async throws {
        let box = try SolutionsSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        // A clone that is already there is used as it is.
        let made = try await SolutionsRepository.create(at: box.folder, repo: box.repo, environment: box.env)
        let adopted = try await SolutionsRepository.useExisting(box.repo, in: box.folder, gh: nil, environment: box.env)
        #expect(adopted.folder == made.folder)
        await #expect(throws: SolutionsError.self) {
            try await SolutionsRepository.useExisting(GitHubRepo(owner: "ada", name: "other")!, in: box.folder, gh: nil, environment: box.env)
        }
        let busy = box.root.appendingPathComponent("busy", isDirectory: true)
        try FileManager.default.createDirectory(at: busy, withIntermediateDirectories: true)
        try "x".write(to: busy.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        await #expect(throws: SolutionsError.self) { try await SolutionsRepository.useExisting(box.repo, in: busy, gh: nil, environment: box.env) }

        // Otherwise it is cloned, here from the bare repository standing in for GitHub.
        let seed = try await SolutionsRepository.create(at: box.root.appendingPathComponent("seed"), repo: box.repo, environment: box.toRemote)
        let place = SolutionsSandbox.place("Var", lesson: 1, slug: "2-var")
        _ = try await seed.commit(Solution(place: place, files: [SolutionFile(name: "main.go", content: "package main\n")], date: SolutionsSandbox.day("2026-10-03")),
                                  index: [place], author: SolutionsSandbox.ada)
        _ = try await seed.push(gh: box.gh)
        let clone = box.root.appendingPathComponent("Documents/go-solutions", isDirectory: true)
        let cloned = try await SolutionsRepository.useExisting(box.repo, in: clone, gh: box.gh, environment: box.toRemote)
        #expect(await cloned.lessonFolders() == ["learn-golang/01-variables/02-var"])
        #expect(await cloned.unpushed() == 0)

        // A folder Finder has opened holds a .DS_Store and nothing else: empty enough to clone into.
        let opened = box.root.appendingPathComponent("Opened in Finder", isDirectory: true)
        try FileManager.default.createDirectory(at: opened, withIntermediateDirectories: true)
        try Data([0]).write(to: opened.appendingPathComponent(".DS_Store"))
        #expect(SolutionsRepository.problem(with: opened, outside: [], mustBeEmpty: true) == nil)
        let intoOpened = try await SolutionsRepository.useExisting(box.repo, in: opened, gh: box.gh, environment: box.toRemote)
        #expect(await intoOpened.lessonFolders() == ["learn-golang/01-variables/02-var"])

        // A clone that can't reach GitHub says so, and nothing about commits waiting for a push.
        let unreachable = box.env.merging(["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "url.https://127.0.0.1:1/ada/go-solutions.git.insteadOf",
                                           "GIT_CONFIG_VALUE_0": SolutionsRepository.remote(box.repo), "GIT_ALLOW_PROTOCOL": "file:https"]) { _, new in new }
        do {
            _ = try await SolutionsRepository.useExisting(box.repo, in: box.root.appendingPathComponent("away"), gh: box.gh, environment: unreachable)
            Issue.record("cloned from an address nothing answers at")
        } catch {
            #expect(error.errorDescription?.hasPrefix("GitHub can't be reached, so ada/go-solutions could not be cloned: fatal: unable to access") == true,
                    "\(error.errorDescription ?? "")")
            #expect(error.errorDescription?.contains("push") == false)
        }
    }

    @Test func aBranchOfYourOwnOrADetachedHead() async throws {
        let box = try SolutionsSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let solutions = try await SolutionsRepository.create(at: box.folder, repo: box.repo, environment: box.toRemote)
        let places = [SolutionsSandbox.place("Run Code", lesson: 0, slug: "1-run-code"), SolutionsSandbox.place("Var", lesson: 1, slug: "2-var"),
                      SolutionsSandbox.place("Constants", chapter: 1, lesson: 0, slug: "1-constants")]
        func solution(_ i: Int) -> Solution {
            Solution(place: places[i], files: [SolutionFile(name: "main.go", content: "package main // \(i)\n")], date: SolutionsSandbox.day("2026-10-0\(i + 1)"))
        }
        #expect(try await solutions.commit(solution(0), index: places, author: SolutionsSandbox.ada) == .committed)
        #expect(try await solutions.push(gh: box.gh) == .pushed(1))
        // Origin names no default branch until it is cloned: main is taken for it.
        #expect(await solutions.branchWarning() == nil)

        // On a branch of your own, only its new commits wait to be pushed, and Settings says
        // they don't count on your contribution graph.
        try box.git(box.folder, "switch", "-q", "-c", "practice")
        #expect(await solutions.branchWarning() == "Commits on practice don't count on your contribution graph; switch to main.")
        #expect(try await solutions.commit(solution(1), index: places, author: SolutionsSandbox.ada) == .committed)
        #expect(await solutions.unpushed() == 1)
        #expect(try await solutions.push(gh: box.gh) == .pushed(1))
        #expect(try box.git(box.remote, "rev-list", "--count", "practice") == "2\n")

        // A clone knows origin's default branch.
        try box.git(box.remote, "symbolic-ref", "HEAD", "refs/heads/practice")
        let clone = try await SolutionsRepository.useExisting(box.repo, in: box.root.appendingPathComponent("clone"), gh: box.gh, environment: box.toRemote)
        #expect(await clone.branchWarning() == nil)
        try box.git(clone.folder, "switch", "-q", "main")
        #expect(await clone.branchWarning() == "Commits on main don't count on your contribution graph; switch to practice.")

        // With HEAD detached, nothing is written or committed, and a push says why.
        try box.git(box.folder, "switch", "-q", "--detach")
        let head = try box.git(box.folder, "rev-parse", "HEAD")
        await #expect(throws: SolutionsError.detached(box.folder.path)) {
            try await solutions.commit(solution(2), index: places, author: SolutionsSandbox.ada)
        }
        #expect(!FileManager.default.fileExists(atPath: box.folder.appendingPathComponent("learn-golang/02-variables").path))
        #expect(try box.git(box.folder, "rev-parse", "HEAD") == head)
        try box.git(box.folder, "-c", "user.name=Ada", "-c", "user.email=ada@example.com", "commit", "-q", "--allow-empty", "-m", "Yours")
        await #expect(throws: SolutionsError.detached(box.folder.path)) { try await solutions.push(gh: box.gh) }
        #expect(SolutionsError.detached(box.folder.path).errorDescription?.contains("git switch") == true)
    }

    @Test func aReadmeOfYourOwnStaysAsItIs() async throws {
        let box = try SolutionsSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let solutions = try await SolutionsRepository.create(at: box.folder, repo: box.repo, environment: box.env)
        #expect(SolutionsReadme.file(in: box.folder) == "README.md") // none yet
        let readme = box.folder.appendingPathComponent("README.md"), mine = "# My Go practice\n\nNotes of my own.\n"
        try mine.write(to: readme, atomically: true, encoding: .utf8)
        try box.git(box.folder, "add", "README.md")
        try box.git(box.folder, "-c", "user.name=Ada", "-c", "user.email=ada@example.com", "commit", "-q", "-m", "Mine")
        #expect(SolutionsReadme.file(in: box.folder) == "SOLUTIONS.md")

        // The table goes to SOLUTIONS.md, and your README is neither changed nor committed.
        let place = SolutionsSandbox.place("Var", lesson: 1, slug: "2-var")
        let solved = Solution(place: place, files: [SolutionFile(name: "main.go", content: "package main\n")], date: SolutionsSandbox.day("2026-10-03"))
        #expect(try await solutions.commit(solved, index: [place], author: SolutionsSandbox.ada) == .committed)
        #expect(try String(contentsOf: readme, encoding: .utf8) == mine)
        #expect(try box.git(box.folder, "show", "--name-only", "--format=", "HEAD").split(separator: "\n").sorted()
            == ["SOLUTIONS.md", "learn-golang/01-variables/02-var/main.go"])
        let table = try String(contentsOf: box.folder.appendingPathComponent("SOLUTIONS.md"), encoding: .utf8)
        #expect(table.hasPrefix(SolutionsReadme.marker + "\n") && table.contains("| [Var](learn-golang/01-variables/02-var/) | Variables | 2026-10-03 |"))

        // A README Gopherwood wrote, with the marker or from before it, is rewritten.
        #expect(SolutionsReadme.isGopherwoods(SolutionsReadme.render(title: "x", rows: [])))
        #expect(SolutionsReadme.isGopherwoods("# go-solutions\n\nMy solutions to Go lessons. Gopherwood commits each one when its Submit passes, dated that day.\n"))
        #expect(!SolutionsReadme.isGopherwoods(mine))
    }

    @Test func foldersNamesAndDates() throws {
        let box = try SolutionsSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let jobloom = box.root.appendingPathComponent("Documents/jobloom", isDirectory: true)
        try FileManager.default.createDirectory(at: jobloom.appendingPathComponent("gopherwood"), withIntermediateDirectories: true)
        #expect(SolutionsRepository.problem(with: jobloom.appendingPathComponent("go-solutions"), outside: [jobloom], mustBeEmpty: true)?.hasPrefix("Choose a folder outside") == true)
        #expect(SolutionsRepository.problem(with: box.root.appendingPathComponent("Documents"), outside: [jobloom], mustBeEmpty: false) != nil) // it holds jobloom
        #expect(SolutionsRepository.problem(with: box.root.appendingPathComponent("Documents/go-solutions"), outside: [jobloom], mustBeEmpty: true) == nil)
        #expect(SolutionsRepository.problem(with: jobloom, outside: [], mustBeEmpty: true)?.contains("isn't empty") == true)

        #expect(SolutionPlace.folderName("1-variables") == "1-variables" && SolutionPlace.folderName("../etc") == "-etc" && SolutionPlace.folderName("..") == nil)
        #expect(SolutionPlace.unnumbered("1-variables") == "variables" && SolutionPlace.unnumbered("12-run-code") == "run-code")
        #expect(SolutionPlace.unnumbered("variables") == "variables" && SolutionPlace.unnumbered("2-") == "2-" && SolutionPlace.unnumbered("-x") == "-x" && SolutionPlace.unnumbered("v2-api") == "v2-api")
        #expect(SolutionPlace(lessonID: "x", lessonTitle: "T", chapterTitle: "C", courseTitle: "Go", courseSlug: "go", chapterPosition: 9, chapterSlug: "a/b",
                              lessonPosition: 11, lessonSlug: ".git").path == "go/10-a-b/12-git")
        #expect(SolutionFile(name: "internal/x.go", content: "").isSafe && !SolutionFile(name: "../x.go", content: "").isSafe)
        #expect(!SolutionFile(name: ".git/config", content: "").isSafe && !SolutionFile(name: "a//b.go", content: "").isSafe)
        #expect(SolutionsReadme.escape("A | B [x]") == "A \\| B \\[x\\]")
        #expect(SolutionsRepository.gitDate(Date(timeIntervalSince1970: 1_800_000_000), timeZone: TimeZone(secondsFromGMT: 4 * 3600)!) == "@1800000000 +0400")
        #expect(SolutionsRepository.gitDate(Date(timeIntervalSince1970: 1_800_000_000), timeZone: TimeZone(secondsFromGMT: -(3 * 3600 + 1800))!) == "@1800000000 -0330")
    }
}

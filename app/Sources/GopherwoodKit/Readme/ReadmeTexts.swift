import Foundation

/// Each lesson's readme as plain text, as the app renders it (no Markdown marks, callout or
/// system markers), for search. Made once per lesson, off the main actor.
public actor ReadmeTexts {
    private var texts: [String: String] = [:]
    /// Counts clears, so text read from a library before a clear is never kept after it.
    private var generation = 0

    public init() {}

    /// Forgets every text: lessons are named by id, which another library or a pull can
    /// reuse with new text.
    public func clear() {
        texts = [:]
        generation += 1
    }

    /// Makes the text of every lesson ahead of time, so search is quick from the start.
    public func warm(_ database: AppDatabase) async throws {
        let started = generation
        let lessons = try await database.readmes()
        guard generation == started else { return }
        for lesson in lessons where texts[lesson.id] == nil {
            texts[lesson.id] = ReadmeTexts.text(lesson.readme, title: lesson.title)
        }
    }

    /// Searches the library: the index's best hits, up to `limit`, kept only when the reader
    /// can see a match, in the title or in the readme as the app renders it; each comes with
    /// an excerpt around its first match. The index also matches words that never show, such
    /// as a code block's language, a callout's marker or a link's address.
    public func search(_ query: String, in database: AppDatabase, limit: Int = 60) async throws -> (hits: [SearchHit], snippets: [String: [Snippet.Part]]) {
        let started = generation
        // Twice as many as shown, so the hits dropped leave room for the next best.
        let candidates = try await database.search(query, limit: 2 * limit)
        let missing = candidates.map(\.id).filter { texts[$0] == nil }
        var unread: [String: (id: String, title: String, readme: String)] = [:]
        if !missing.isEmpty {
            for lesson in try await database.readmes(missing) { unread[lesson.id] = lesson }
        }
        // Cleared meanwhile: the library this search read is gone.
        guard generation == started else { throw CancellationError() }
        var hits: [SearchHit] = [], snippets: [String: [Snippet.Part]] = [:]
        for hit in candidates where hits.count < limit {
            if let lesson = unread.removeValue(forKey: hit.id) { texts[hit.id] = ReadmeTexts.text(lesson.readme, title: lesson.title) }
            let text = texts[hit.id] ?? ""
            guard Snippet.shows(query, in: hit.title) || Snippet.shows(query, in: text) else { continue }
            hits.append(hit)
            snippets[hit.id] = Snippet.make(text, query: query)
        }
        return (hits, snippets)
    }

    static func text(_ readme: String, title: String) -> String {
        Readme.plainText(Readme.parse(readme, droppingTitle: title))
    }
}

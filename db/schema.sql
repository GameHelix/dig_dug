-- Gopherwood's database: the lessons, refreshed by sync/, and your study data, kept by the app.
--
-- One file: ~/Library/Application Support/Gopherwood/gopherwood.sqlite.
-- No pictures or videos are stored. sync/ removes images and video embeds from every readme and
-- lesson payload before they land here.
--
-- The lesson tables are content: sync/ may replace any row in them. Your data (progress,
-- attempt, note, project, setting) is keyed by uuid and never deleted by a sync, so a lesson
-- that disappears and comes back keeps its history.

PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS course (
  uuid              TEXT PRIMARY KEY,
  slug              TEXT NOT NULL UNIQUE,
  title             TEXT NOT NULL,
  kind              TEXT NOT NULL,             -- 'Course' or 'Guided Project', as boot.dev names it
  short_description TEXT NOT NULL DEFAULT '',
  description       TEXT NOT NULL DEFAULT '',
  position          INTEGER NOT NULL           -- order in boot.dev's catalog
);

CREATE TABLE IF NOT EXISTS chapter (
  uuid        TEXT PRIMARY KEY,
  course_uuid TEXT NOT NULL REFERENCES course(uuid) ON DELETE CASCADE,
  slug        TEXT NOT NULL,
  title       TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  position    INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS chapter_course ON chapter(course_uuid, position);

CREATE TABLE IF NOT EXISTS lesson (
  uuid         TEXT PRIMARY KEY,
  chapter_uuid TEXT NOT NULL REFERENCES chapter(uuid) ON DELETE CASCADE,
  position     INTEGER NOT NULL,
  slug         TEXT NOT NULL,
  title        TEXT NOT NULL,
  type         TEXT NOT NULL CHECK (type IN ('type_code', 'type_code_tests', 'type_choice',
                                             'type_cli', 'type_github_checks', 'type_interview_chat')),
  required     INTEGER NOT NULL DEFAULT 1,     -- 0 for an optional lesson
  difficulty   INTEGER,                        -- boot.dev's absoluteDifficulty
  readme       TEXT NOT NULL DEFAULT '',       -- Markdown, images and videos removed
  -- The type's own payload as JSON, without its readme and without media:
  --   type_code            {"progLang", "starterFiles": [{name, content, isHidden, isReadonly}], "codeExpectedOutput"}
  --   type_code_tests      {"progLang", "starterFiles": [...]}
  --   type_choice          {"questions": [...], "containsCompleteDir"}
  --   type_cli             {"cliData": {...}}
  --   type_github_checks   {"gitHubChecks": [...]}
  --   type_interview_chat  {"studentPrompt", "acceptanceCriteria"}
  data         TEXT NOT NULL DEFAULT '{}',
  last_mod     TEXT,                           -- boot.dev's lastMod, so a sync refreshes only what changed
  synced_at    TEXT NOT NULL                   -- RFC 3339, UTC
);
CREATE INDEX IF NOT EXISTS lesson_chapter ON lesson(chapter_uuid, position);

-- Full-text search over lesson titles and readmes, kept in step by the triggers below.
CREATE VIRTUAL TABLE IF NOT EXISTS lesson_search USING fts5(
  title, readme, content = 'lesson', content_rowid = 'rowid', tokenize = 'unicode61 remove_diacritics 2'
);
CREATE TRIGGER IF NOT EXISTS lesson_search_insert AFTER INSERT ON lesson BEGIN
  INSERT INTO lesson_search(rowid, title, readme) VALUES (new.rowid, new.title, new.readme);
END;
CREATE TRIGGER IF NOT EXISTS lesson_search_delete AFTER DELETE ON lesson BEGIN
  INSERT INTO lesson_search(lesson_search, rowid, title, readme) VALUES ('delete', old.rowid, old.title, old.readme);
END;
CREATE TRIGGER IF NOT EXISTS lesson_search_update AFTER UPDATE ON lesson BEGIN
  INSERT INTO lesson_search(lesson_search, rowid, title, readme) VALUES ('delete', old.rowid, old.title, old.readme);
  INSERT INTO lesson_search(rowid, title, readme) VALUES (new.rowid, new.title, new.readme);
END;

-- Your study data. All timestamps are RFC 3339, UTC.

CREATE TABLE IF NOT EXISTS progress (
  lesson_uuid    TEXT PRIMARY KEY,
  done_at        TEXT,                         -- NULL while the lesson is not done
  last_opened_at TEXT
);

-- Every Run, Submit, quiz answer and command-line check, passed or not.
CREATE TABLE IF NOT EXISTS attempt (
  id          INTEGER PRIMARY KEY,
  lesson_uuid TEXT NOT NULL,
  kind        TEXT NOT NULL CHECK (kind IN ('run', 'submit', 'answer', 'check')),
  passed      INTEGER NOT NULL CHECK (passed IN (0, 1)),
  output      TEXT NOT NULL DEFAULT '',
  duration_ms INTEGER,
  at          TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS attempt_lesson ON attempt(lesson_uuid, at);

CREATE TABLE IF NOT EXISTS note (
  lesson_uuid TEXT PRIMARY KEY,
  body        TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);

-- The folder a course's command-line lessons run in, and the address of your own server that
-- their HTTP checks call.
CREATE TABLE IF NOT EXISTS project (
  course_uuid TEXT PRIMARY KEY,
  dir         TEXT NOT NULL,
  base_url    TEXT NOT NULL DEFAULT ''
);

-- Small app state: last_lesson (a lesson uuid), editor font size, window choices.
CREATE TABLE IF NOT EXISTS setting (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

PRAGMA user_version = 1;

-- Gopherwood's database: one SQLite file, data/gopherwood.sqlite in this repository, committed
-- to git as it is. It holds the lessons, your progress, every attempt, notes and your code. No
-- JSON or other data files. The sync tool (cmd/sync) fills the lesson tables and the app the
-- rest; the app commits only this file. It uses the rollback journal (journal_mode DELETE, never
-- WAL), so the file is whole whenever no write is under way.
--
-- Conventions:
--   * Every table is STRICT, so a column only ever holds its declared type.
--   * Booleans are INTEGER 0 or 1. Timestamps are RFC 3339 in UTC with a trailing Z, such as
--     2026-10-31T12:00:00Z (fractional seconds allowed). An optional value that is missing is
--     NULL, not ''. Lists keep their order in a `position` column counted from 0.
--   * A row that belongs to one kind of parent carries that kind in a column pinned by CHECK
--     and references the parent's (key, kind), so a cli_lesson row can only belong to a type_cli
--     lesson, an HTTP request only to an HTTP step, and so on.
--   * Every connection sets PRAGMA foreign_keys = ON; SQLite does not remember it.
--   * The lesson tables are content: the sync tool refreshes them and never deletes a lesson, so
--     your data keeps pointing at it. Your tables reference lessons without ON DELETE, so a
--     lesson that holds your progress, attempts, notes or code cannot be deleted by accident.
--   * This file makes a new, empty database; it is never run against an existing one. A change
--     raises user_version and comes with a migration in the db package (db/migrate.go), which
--     the sync tool runs when it opens an older file. The app opens only the version it was
--     built for.
--   * No pictures, videos or interactive widgets: the sync tool removes them before anything
--     lands here.

PRAGMA foreign_keys = ON;

------------------------------------------------------------------------------------------------
-- The catalog
------------------------------------------------------------------------------------------------

CREATE TABLE course (
  uuid              TEXT PRIMARY KEY,
  slug              TEXT NOT NULL UNIQUE,
  title             TEXT NOT NULL,
  kind              TEXT NOT NULL CHECK (kind IN ('Course', 'Guided Project')),
  short_description TEXT NOT NULL,
  description       TEXT NOT NULL,
  position          INTEGER NOT NULL UNIQUE CHECK (position >= 0)  -- order in the catalog
) STRICT;

CREATE TABLE chapter (
  uuid        TEXT PRIMARY KEY,
  course_uuid TEXT NOT NULL REFERENCES course(uuid) ON DELETE CASCADE,
  position    INTEGER NOT NULL CHECK (position >= 0),
  slug        TEXT NOT NULL,
  title       TEXT NOT NULL,
  description TEXT NOT NULL,
  UNIQUE (course_uuid, position),
  UNIQUE (course_uuid, slug)
) STRICT;

CREATE TABLE lesson (
  id            INTEGER PRIMARY KEY,           -- stable row id for lesson_search; VACUUM keeps it
  uuid          TEXT NOT NULL UNIQUE,
  chapter_uuid  TEXT NOT NULL REFERENCES chapter(uuid) ON DELETE CASCADE,
  position      INTEGER NOT NULL CHECK (position >= 0),
  slug          TEXT NOT NULL,
  title         TEXT NOT NULL,
  type          TEXT NOT NULL CHECK (type IN ('type_code', 'type_code_tests', 'type_choice',
                                              'type_cli', 'type_github_checks', 'type_interview_chat')),
  required      INTEGER NOT NULL CHECK (required IN (0, 1)),
  difficulty    INTEGER NOT NULL CHECK (difficulty > 0),             -- the source's difficulty score
  readme        TEXT NOT NULL,                                       -- Markdown, images and videos removed
  created_at    TEXT NOT NULL CHECK (created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*Z' AND julianday(created_at) IS NOT NULL),
  last_mod      TEXT NOT NULL CHECK (last_mod GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*Z' AND julianday(last_mod) IS NOT NULL),
  code_last_mod TEXT CHECK (code_last_mod IS NULL OR (code_last_mod GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*Z' AND julianday(code_last_mod) IS NOT NULL)),
  synced_at     TEXT NOT NULL CHECK (synced_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*Z' AND julianday(synced_at) IS NOT NULL),
  UNIQUE (chapter_uuid, position),
  UNIQUE (chapter_uuid, slug),
  UNIQUE (uuid, type)                          -- what the per-type tables reference
) STRICT;
-- last_mod and code_last_mod are when the lesson and its starter code last changed at the
-- source, so a sync rewrites only what changed. synced_at is when the sync tool last
-- confirmed the lesson against the source.

CREATE TABLE lesson_topic (
  lesson_uuid TEXT NOT NULL REFERENCES lesson(uuid) ON DELETE CASCADE,
  topic       TEXT NOT NULL CHECK (topic <> ''),
  PRIMARY KEY (lesson_uuid, topic)
) STRICT;
CREATE INDEX lesson_topic_topic ON lesson_topic(topic);

-- Full-text search over lesson titles and readmes, kept in step by the triggers below.
CREATE VIRTUAL TABLE lesson_search USING fts5(
  title, readme, content = 'lesson', content_rowid = 'id', tokenize = 'unicode61 remove_diacritics 2'
);
CREATE TRIGGER lesson_search_insert AFTER INSERT ON lesson BEGIN
  INSERT INTO lesson_search(rowid, title, readme) VALUES (new.id, new.title, new.readme);
END;
CREATE TRIGGER lesson_search_delete AFTER DELETE ON lesson BEGIN
  INSERT INTO lesson_search(lesson_search, rowid, title, readme) VALUES ('delete', old.id, old.title, old.readme);
END;
CREATE TRIGGER lesson_search_update AFTER UPDATE OF title, readme ON lesson BEGIN
  INSERT INTO lesson_search(lesson_search, rowid, title, readme) VALUES ('delete', old.id, old.title, old.readme);
  INSERT INTO lesson_search(rowid, title, readme) VALUES (new.id, new.title, new.readme);
END;

------------------------------------------------------------------------------------------------
-- Code lessons: type_code (checked by what the program prints) and type_code_tests (checked by
-- its tests)
------------------------------------------------------------------------------------------------

CREATE TABLE code_lesson (
  lesson_uuid     TEXT PRIMARY KEY,
  lesson_type     TEXT NOT NULL CHECK (lesson_type IN ('type_code', 'type_code_tests')),
  prog_lang       TEXT NOT NULL CHECK (prog_lang <> ''),
  expected_output TEXT,                        -- type_code: what the program must print
  CHECK ((lesson_type = 'type_code') = (expected_output IS NOT NULL)),
  FOREIGN KEY (lesson_uuid, lesson_type) REFERENCES lesson(uuid, type) ON DELETE CASCADE
) STRICT;

CREATE TABLE starter_file (
  lesson_uuid TEXT NOT NULL REFERENCES code_lesson(lesson_uuid) ON DELETE CASCADE,
  name        TEXT NOT NULL CHECK (name <> ''),  -- path inside the lesson, e.g. main.go
  position    INTEGER NOT NULL CHECK (position >= 0),
  content     TEXT NOT NULL,
  is_hidden   INTEGER NOT NULL CHECK (is_hidden IN (0, 1)),    -- added at build time, never shown
  is_readonly INTEGER NOT NULL CHECK (is_readonly IN (0, 1)),  -- shown but not editable, like the tests
  PRIMARY KEY (lesson_uuid, name),
  UNIQUE (lesson_uuid, position)
) STRICT;

------------------------------------------------------------------------------------------------
-- Quizzes: type_choice
------------------------------------------------------------------------------------------------

CREATE TABLE quiz_lesson (
  lesson_uuid           TEXT PRIMARY KEY,
  lesson_type           TEXT NOT NULL DEFAULT 'type_choice' CHECK (lesson_type = 'type_choice'),
  contains_complete_dir INTEGER NOT NULL CHECK (contains_complete_dir IN (0, 1)),
  FOREIGN KEY (lesson_uuid, lesson_type) REFERENCES lesson(uuid, type) ON DELETE CASCADE
) STRICT;

CREATE TABLE quiz_question (
  lesson_uuid TEXT NOT NULL REFERENCES quiz_lesson(lesson_uuid) ON DELETE CASCADE,
  position    INTEGER NOT NULL CHECK (position >= 0),
  question    TEXT NOT NULL,
  PRIMARY KEY (lesson_uuid, position)
) STRICT;

CREATE TABLE quiz_answer (
  lesson_uuid       TEXT NOT NULL,
  question_position INTEGER NOT NULL,
  position          INTEGER NOT NULL CHECK (position >= 0),
  answer            TEXT NOT NULL,
  is_correct        INTEGER NOT NULL CHECK (is_correct IN (0, 1)),
  PRIMARY KEY (lesson_uuid, question_position, position),
  UNIQUE (lesson_uuid, question_position, answer),
  FOREIGN KEY (lesson_uuid, question_position)
    REFERENCES quiz_question(lesson_uuid, position) ON DELETE CASCADE
) STRICT;
-- Exactly one right answer per question: this index allows at most one, the sync tool checks there is one.
CREATE UNIQUE INDEX quiz_answer_one_correct
  ON quiz_answer(lesson_uuid, question_position) WHERE is_correct = 1;

------------------------------------------------------------------------------------------------
-- Command-line lessons: type_cli. A lesson is a list of steps; each step runs a shell command
-- or makes an HTTP request, then checks the result with its tests. Values a step captures are
-- used by later steps as ${name}.
------------------------------------------------------------------------------------------------

CREATE TABLE cli_lesson (
  lesson_uuid           TEXT PRIMARY KEY,
  lesson_type           TEXT NOT NULL DEFAULT 'type_cli' CHECK (lesson_type = 'type_cli'),
  -- The address of your server the lesson suggests, such as http://localhost:8080; always a
  -- real address. Where you run that server elsewhere, server_address says where.
  base_url_default      TEXT CHECK (base_url_default <> '' AND base_url_default <> 'override'),
  -- 1: the lesson needs the address of your own server, such as an app you deployed, and
  -- suggests none (the source marks these 'override'). project.base_url holds it.
  asks_for_base_url     INTEGER NOT NULL DEFAULT 0 CHECK (asks_for_base_url IN (0, 1)),
  use_agent_prompt      INTEGER NOT NULL CHECK (use_agent_prompt IN (0, 1)),
  contains_complete_dir INTEGER NOT NULL CHECK (contains_complete_dir IN (0, 1)),
  CHECK (asks_for_base_url = 0 OR base_url_default IS NULL),
  FOREIGN KEY (lesson_uuid, lesson_type) REFERENCES lesson(uuid, type) ON DELETE CASCADE
) STRICT;

CREATE TABLE cli_lesson_os (
  lesson_uuid TEXT NOT NULL REFERENCES cli_lesson(lesson_uuid) ON DELETE CASCADE,
  os          TEXT NOT NULL CHECK (os IN ('linux', 'darwin', 'windows')),
  PRIMARY KEY (lesson_uuid, os)
) STRICT;

CREATE TABLE cli_step (
  lesson_uuid        TEXT NOT NULL REFERENCES cli_lesson(lesson_uuid) ON DELETE CASCADE,
  position           INTEGER NOT NULL CHECK (position >= 0),
  kind               TEXT NOT NULL CHECK (kind IN ('command', 'http')),
  description        TEXT NOT NULL,
  no_penalty_on_fail INTEGER NOT NULL CHECK (no_penalty_on_fail IN (0, 1)),
  sleep_after_ms     INTEGER CHECK (sleep_after_ms > 0),  -- a pause after the step, if any
  PRIMARY KEY (lesson_uuid, position),
  UNIQUE (lesson_uuid, position, kind)
) STRICT;

-- A command step.
CREATE TABLE cli_command (
  lesson_uuid        TEXT NOT NULL,
  step_position      INTEGER NOT NULL,
  step_kind          TEXT NOT NULL DEFAULT 'command' CHECK (step_kind = 'command'),
  command            TEXT NOT NULL CHECK (command <> ''),
  stdout_filter_tmdl TEXT,
  PRIMARY KEY (lesson_uuid, step_position),
  FOREIGN KEY (lesson_uuid, step_position, step_kind)
    REFERENCES cli_step(lesson_uuid, position, kind) ON DELETE CASCADE
) STRICT;

-- A value a command step captures from its output: the first group of regex.
CREATE TABLE cli_command_variable (
  lesson_uuid   TEXT NOT NULL,
  step_position INTEGER NOT NULL,
  position      INTEGER NOT NULL CHECK (position >= 0),
  name          TEXT NOT NULL CHECK (name <> ''),
  regex         TEXT NOT NULL CHECK (regex <> ''),
  PRIMARY KEY (lesson_uuid, step_position, position),
  UNIQUE (lesson_uuid, step_position, name),
  FOREIGN KEY (lesson_uuid, step_position)
    REFERENCES cli_command(lesson_uuid, step_position) ON DELETE CASCADE
) STRICT;

-- One check of a command's result. Each row is one kind and sets only that kind's columns.
CREATE TABLE cli_command_test (
  lesson_uuid   TEXT NOT NULL,
  step_position INTEGER NOT NULL,
  position      INTEGER NOT NULL CHECK (position >= 0),
  kind          TEXT NOT NULL CHECK (kind IN ('exit_code', 'stdout_contains_all', 'stdout_contains_none',
                                              'stdout_lines_gt', 'stdout_jq')),
  exit_code     INTEGER,
  lines_gt      INTEGER CHECK (lines_gt >= 0),
  jq_query      TEXT CHECK (jq_query <> ''),
  jq_input      TEXT CHECK (jq_input IN ('json', 'jsonl')),  -- stdout is one JSON value, or one per line
  CHECK ((kind = 'exit_code') = (exit_code IS NOT NULL)),
  CHECK ((kind = 'stdout_lines_gt') = (lines_gt IS NOT NULL)),
  CHECK ((kind = 'stdout_jq') = (jq_query IS NOT NULL)),
  CHECK ((kind = 'stdout_jq') = (jq_input IS NOT NULL)),
  PRIMARY KEY (lesson_uuid, step_position, position),
  UNIQUE (lesson_uuid, step_position, position, kind),
  FOREIGN KEY (lesson_uuid, step_position)
    REFERENCES cli_command(lesson_uuid, step_position) ON DELETE CASCADE
) STRICT;

-- The strings a stdout_contains_all test needs in the output, or a stdout_contains_none test
-- must not find there.
CREATE TABLE cli_command_test_text (
  lesson_uuid   TEXT NOT NULL,
  step_position INTEGER NOT NULL,
  test_position INTEGER NOT NULL,
  test_kind     TEXT NOT NULL CHECK (test_kind IN ('stdout_contains_all', 'stdout_contains_none')),
  position      INTEGER NOT NULL CHECK (position >= 0),
  text          TEXT NOT NULL,
  PRIMARY KEY (lesson_uuid, step_position, test_position, position),
  FOREIGN KEY (lesson_uuid, step_position, test_position, test_kind)
    REFERENCES cli_command_test(lesson_uuid, step_position, position, kind) ON DELETE CASCADE
) STRICT;

-- What a stdout_jq test expects: the query's result compared with a typed value.
CREATE TABLE cli_command_test_jq_result (
  lesson_uuid   TEXT NOT NULL,
  step_position INTEGER NOT NULL,
  test_position INTEGER NOT NULL,
  test_kind     TEXT NOT NULL DEFAULT 'stdout_jq' CHECK (test_kind = 'stdout_jq'),
  position      INTEGER NOT NULL CHECK (position >= 0),
  operator      TEXT NOT NULL CHECK (operator IN ('==', '!=', '>', '>=', '<', '<=')),
  value_type    TEXT NOT NULL CHECK (value_type IN ('bool', 'int', 'string')),
  bool_value    INTEGER CHECK (bool_value IN (0, 1)),
  int_value     INTEGER,
  string_value  TEXT,
  CHECK ((value_type = 'bool') = (bool_value IS NOT NULL)),
  CHECK ((value_type = 'int') = (int_value IS NOT NULL)),
  CHECK ((value_type = 'string') = (string_value IS NOT NULL)),
  PRIMARY KEY (lesson_uuid, step_position, test_position, position),
  FOREIGN KEY (lesson_uuid, step_position, test_position, test_kind)
    REFERENCES cli_command_test(lesson_uuid, step_position, position, kind) ON DELETE CASCADE
) STRICT;

-- An HTTP request step. full_url and header values may hold ${baseURL} and captured ${names}.
CREATE TABLE cli_http_request (
  lesson_uuid         TEXT NOT NULL,
  step_position       INTEGER NOT NULL,
  step_kind           TEXT NOT NULL DEFAULT 'http' CHECK (step_kind = 'http'),
  method              TEXT NOT NULL CHECK (method IN ('GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS')),
  full_url            TEXT NOT NULL CHECK (full_url <> ''),
  follow_redirects    INTEGER NOT NULL CHECK (follow_redirects IN (0, 1)),
  basic_auth_username TEXT,
  basic_auth_password TEXT,
  body_kind           TEXT CHECK (body_kind IN ('json', 'form')),  -- NULL: no body
  -- For a JSON body, the body itself as the lesson sends it to your server: an HTTP payload,
  -- kept whole like a starter file's content. A form body is in cli_http_form_field.
  body_json           TEXT CHECK (json_valid(body_json)),
  CHECK ((basic_auth_username IS NULL) = (basic_auth_password IS NULL)),
  CHECK ((body_kind IS 'json') = (body_json IS NOT NULL)),
  PRIMARY KEY (lesson_uuid, step_position),
  UNIQUE (lesson_uuid, step_position, body_kind),
  FOREIGN KEY (lesson_uuid, step_position, step_kind)
    REFERENCES cli_step(lesson_uuid, position, kind) ON DELETE CASCADE
) STRICT;

CREATE TABLE cli_http_header (
  lesson_uuid   TEXT NOT NULL,
  step_position INTEGER NOT NULL,
  position      INTEGER NOT NULL CHECK (position >= 0),
  name          TEXT NOT NULL CHECK (name <> ''),
  value         TEXT NOT NULL,
  PRIMARY KEY (lesson_uuid, step_position, position),
  UNIQUE (lesson_uuid, step_position, name COLLATE NOCASE),  -- header names ignore case
  FOREIGN KEY (lesson_uuid, step_position)
    REFERENCES cli_http_request(lesson_uuid, step_position) ON DELETE CASCADE
) STRICT;

CREATE TABLE cli_http_form_field (
  lesson_uuid   TEXT NOT NULL,
  step_position INTEGER NOT NULL,
  body_kind     TEXT NOT NULL DEFAULT 'form' CHECK (body_kind = 'form'),
  position      INTEGER NOT NULL CHECK (position >= 0),
  name          TEXT NOT NULL CHECK (name <> ''),
  value         TEXT NOT NULL,
  PRIMARY KEY (lesson_uuid, step_position, position),
  UNIQUE (lesson_uuid, step_position, name),
  FOREIGN KEY (lesson_uuid, step_position, body_kind)
    REFERENCES cli_http_request(lesson_uuid, step_position, body_kind) ON DELETE CASCADE
) STRICT;

-- A value an HTTP step captures from the response body: the value at a JSON path, or the
-- first group of a regex over the body.
CREATE TABLE cli_http_body_variable (
  lesson_uuid   TEXT NOT NULL,
  step_position INTEGER NOT NULL,
  position      INTEGER NOT NULL CHECK (position >= 0),
  name          TEXT NOT NULL CHECK (name <> ''),
  json_path     TEXT CHECK (json_path <> ''),
  regex         TEXT CHECK (regex <> ''),
  CHECK ((json_path IS NULL) <> (regex IS NULL)),
  PRIMARY KEY (lesson_uuid, step_position, position),
  UNIQUE (lesson_uuid, step_position, name),
  FOREIGN KEY (lesson_uuid, step_position)
    REFERENCES cli_http_request(lesson_uuid, step_position) ON DELETE CASCADE
) STRICT;

-- A value an HTTP step captures from a response header: its whole value, or the first group
-- of a regex over it.
CREATE TABLE cli_http_header_variable (
  lesson_uuid   TEXT NOT NULL,
  step_position INTEGER NOT NULL,
  position      INTEGER NOT NULL CHECK (position >= 0),
  name          TEXT NOT NULL CHECK (name <> ''),
  header        TEXT NOT NULL CHECK (header <> ''),
  regex         TEXT CHECK (regex <> ''),
  PRIMARY KEY (lesson_uuid, step_position, position),
  UNIQUE (lesson_uuid, step_position, name),
  FOREIGN KEY (lesson_uuid, step_position)
    REFERENCES cli_http_request(lesson_uuid, step_position) ON DELETE CASCADE
) STRICT;

-- One check of an HTTP response. Each row is one kind and sets only that kind's columns:
-- status_code; text for body_contains and body_contains_none; field_name and field_value for
-- the header and trailer checks; json_path, json_operator and one typed value for json_value.
CREATE TABLE cli_http_test (
  lesson_uuid   TEXT NOT NULL,
  step_position INTEGER NOT NULL,
  position      INTEGER NOT NULL CHECK (position >= 0),
  kind          TEXT NOT NULL CHECK (kind IN ('status_code', 'body_contains', 'body_contains_none',
                                              'headers_contain', 'headers_equal', 'trailers_contain',
                                              'trailers_equal', 'json_value')),
  status_code   INTEGER CHECK (status_code BETWEEN 100 AND 599),
  text          TEXT,
  field_name    TEXT CHECK (field_name <> ''),
  field_value   TEXT,
  json_path     TEXT CHECK (json_path <> ''),
  json_operator TEXT CHECK (json_operator IN ('eq', 'ne', 'gt', 'gte', 'lt', 'lte', 'contains', 'not_contains')),
  value_type    TEXT CHECK (value_type IN ('bool', 'int', 'string')),
  bool_value    INTEGER CHECK (bool_value IN (0, 1)),
  int_value     INTEGER,
  string_value  TEXT,
  CHECK ((kind = 'status_code') = (status_code IS NOT NULL)),
  CHECK ((kind IN ('body_contains', 'body_contains_none')) = (text IS NOT NULL)),
  CHECK ((kind IN ('headers_contain', 'headers_equal', 'trailers_contain', 'trailers_equal')) = (field_name IS NOT NULL)),
  CHECK ((kind IN ('headers_contain', 'headers_equal', 'trailers_contain', 'trailers_equal')) = (field_value IS NOT NULL)),
  CHECK ((kind = 'json_value') = (json_path IS NOT NULL)),
  CHECK ((kind = 'json_value') = (json_operator IS NOT NULL)),
  CHECK ((kind = 'json_value') = (value_type IS NOT NULL)),
  CHECK ((value_type IS 'bool') = (bool_value IS NOT NULL)),
  CHECK ((value_type IS 'int') = (int_value IS NOT NULL)),
  CHECK ((value_type IS 'string') = (string_value IS NOT NULL)),
  PRIMARY KEY (lesson_uuid, step_position, position),
  FOREIGN KEY (lesson_uuid, step_position)
    REFERENCES cli_http_request(lesson_uuid, step_position) ON DELETE CASCADE
) STRICT;

------------------------------------------------------------------------------------------------
-- GitHub lessons: type_github_checks. Shown to read and marked done by hand.
------------------------------------------------------------------------------------------------

CREATE TABLE github_lesson (
  lesson_uuid           TEXT PRIMARY KEY,
  lesson_type           TEXT NOT NULL DEFAULT 'type_github_checks' CHECK (lesson_type = 'type_github_checks'),
  showcase_repo         INTEGER NOT NULL CHECK (showcase_repo IN (0, 1)),
  contains_complete_dir INTEGER NOT NULL CHECK (contains_complete_dir IN (0, 1)),
  FOREIGN KEY (lesson_uuid, lesson_type) REFERENCES lesson(uuid, type) ON DELETE CASCADE
) STRICT;

-- One check of your GitHub repository. Each row is one kind and sets only that kind's columns.
CREATE TABLE github_step (
  lesson_uuid       TEXT NOT NULL REFERENCES github_lesson(lesson_uuid) ON DELETE CASCADE,
  position          INTEGER NOT NULL CHECK (position >= 0),
  kind              TEXT NOT NULL CHECK (kind IN ('repo_exists', 'submit_repo_for_course', 'branch_exists',
                                                  'file_contains', 'pr_exists', 'workflow_status',
                                                  'workflow_logs_contains')),
  branch_name       TEXT CHECK (branch_name <> ''),        -- branch_exists
  file_path         TEXT CHECK (file_path <> ''),          -- file_contains
  pr_base_owner     TEXT CHECK (pr_base_owner <> ''),      -- pr_exists: the branch the pull request
  pr_base_repo      TEXT CHECK (pr_base_repo <> ''),       -- targets (in your repository unless
  pr_base_branch    TEXT CHECK (pr_base_branch <> ''),     -- an owner and repo are given) and the
  pr_compare_branch TEXT CHECK (pr_compare_branch <> ''),  -- branch it brings in
  workflow_name     TEXT CHECK (workflow_name <> ''),      -- workflow_status, workflow_logs_contains
  workflow_status   TEXT CHECK (workflow_status IN ('success', 'failure')),
  CHECK ((kind = 'branch_exists') = (branch_name IS NOT NULL)),
  CHECK ((kind = 'file_contains') = (file_path IS NOT NULL)),
  CHECK (kind = 'pr_exists' OR pr_base_owner IS NULL),
  CHECK ((pr_base_owner IS NULL) = (pr_base_repo IS NULL)),
  CHECK ((kind = 'pr_exists') = (pr_base_branch IS NOT NULL)),
  CHECK ((kind = 'pr_exists') = (pr_compare_branch IS NOT NULL)),
  CHECK ((kind IN ('workflow_status', 'workflow_logs_contains')) = (workflow_name IS NOT NULL)),
  CHECK ((kind = 'workflow_status') = (workflow_status IS NOT NULL)),
  PRIMARY KEY (lesson_uuid, position),
  UNIQUE (lesson_uuid, position, kind)
) STRICT;

-- The strings a file_contains step expects in the file.
CREATE TABLE github_file_text (
  lesson_uuid   TEXT NOT NULL,
  step_position INTEGER NOT NULL,
  step_kind     TEXT NOT NULL DEFAULT 'file_contains' CHECK (step_kind = 'file_contains'),
  position      INTEGER NOT NULL CHECK (position >= 0),
  text          TEXT NOT NULL,
  PRIMARY KEY (lesson_uuid, step_position, position),
  FOREIGN KEY (lesson_uuid, step_position, step_kind)
    REFERENCES github_step(lesson_uuid, position, kind) ON DELETE CASCADE
) STRICT;

-- The strings a workflow_logs_contains step expects in a job's log.
CREATE TABLE github_log_text (
  lesson_uuid   TEXT NOT NULL,
  step_position INTEGER NOT NULL,
  step_kind     TEXT NOT NULL DEFAULT 'workflow_logs_contains' CHECK (step_kind = 'workflow_logs_contains'),
  job           TEXT NOT NULL CHECK (job <> ''),
  position      INTEGER NOT NULL CHECK (position >= 0),
  text          TEXT NOT NULL,
  PRIMARY KEY (lesson_uuid, step_position, job, position),
  FOREIGN KEY (lesson_uuid, step_position, step_kind)
    REFERENCES github_step(lesson_uuid, position, kind) ON DELETE CASCADE
) STRICT;

------------------------------------------------------------------------------------------------
-- Interview lessons: type_interview_chat. Shown to read and marked done by hand.
------------------------------------------------------------------------------------------------

CREATE TABLE interview_lesson (
  lesson_uuid         TEXT PRIMARY KEY,
  lesson_type         TEXT NOT NULL DEFAULT 'type_interview_chat' CHECK (lesson_type = 'type_interview_chat'),
  student_prompt      TEXT NOT NULL,
  acceptance_criteria TEXT NOT NULL,
  FOREIGN KEY (lesson_uuid, lesson_type) REFERENCES lesson(uuid, type) ON DELETE CASCADE
) STRICT;

------------------------------------------------------------------------------------------------
-- Your data
------------------------------------------------------------------------------------------------

CREATE TABLE progress (
  lesson_uuid    TEXT PRIMARY KEY REFERENCES lesson(uuid),
  done_at        TEXT CHECK (done_at IS NULL OR (done_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*Z' AND julianday(done_at) IS NOT NULL)),  -- NULL until done
  last_opened_at TEXT CHECK (last_opened_at IS NULL OR (last_opened_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*Z' AND julianday(last_opened_at) IS NOT NULL)),
  CHECK (done_at IS NOT NULL OR last_opened_at IS NOT NULL)
) STRICT;
CREATE INDEX progress_last_opened ON progress(last_opened_at);

-- Every Run, Submit, quiz answer and command-line check, passed or not.
CREATE TABLE attempt (
  id          INTEGER PRIMARY KEY,
  lesson_uuid TEXT NOT NULL REFERENCES lesson(uuid),
  kind        TEXT NOT NULL CHECK (kind IN ('run', 'submit', 'answer', 'check')),
  passed      INTEGER NOT NULL CHECK (passed IN (0, 1)),
  output      TEXT NOT NULL,                   -- what the run printed, or the answer you picked
  duration_ms INTEGER CHECK (duration_ms >= 0),
  at          TEXT NOT NULL CHECK (at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*Z' AND julianday(at) IS NOT NULL)
) STRICT;
CREATE INDEX attempt_lesson ON attempt(lesson_uuid, at);

CREATE TABLE note (
  lesson_uuid TEXT PRIMARY KEY REFERENCES lesson(uuid),
  body        TEXT NOT NULL,
  updated_at  TEXT NOT NULL CHECK (updated_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*Z' AND julianday(updated_at) IS NOT NULL)
) STRICT;

-- Your code, one row per file. The app writes a lesson's files to a scratch folder only to
-- build, run and test them (and to open them in an editor), and reads them back from there.
CREATE TABLE code_file (
  lesson_uuid TEXT NOT NULL REFERENCES lesson(uuid),
  name        TEXT NOT NULL CHECK (name <> ''),  -- path inside the lesson, e.g. main.go
  content     TEXT NOT NULL,
  updated_at  TEXT NOT NULL CHECK (updated_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*Z' AND julianday(updated_at) IS NOT NULL),
  PRIMARY KEY (lesson_uuid, name)
) STRICT;

-- The folder a course's command-line lessons run in, and the address of your own server for
-- the lessons that ask for one (cli_lesson.asks_for_base_url). Either may be missing, not both.
CREATE TABLE project (
  course_uuid TEXT PRIMARY KEY REFERENCES course(uuid),
  dir         TEXT CHECK (dir <> ''),
  base_url    TEXT CHECK (base_url <> ''),
  CHECK (dir IS NOT NULL OR base_url IS NOT NULL)
) STRICT;

-- The address you run a lesson's server at when it is not the one the lesson suggests
-- (cli_lesson.base_url_default). Lessons that suggest the same address share it: a course's
-- lessons often use several servers, such as an app on :8080 and Grafana on :3000.
CREATE TABLE server_address (
  default_url TEXT PRIMARY KEY CHECK (default_url <> ''),  -- the address the lessons suggest
  url         TEXT NOT NULL CHECK (url <> '')              -- where your server answers instead
) STRICT;

-- App preferences that follow you between laptops, such as the editor font size. The last
-- lesson you opened is the newest progress.last_opened_at, not a setting.
CREATE TABLE setting (
  key   TEXT PRIMARY KEY CHECK (key <> ''),
  value TEXT NOT NULL
) STRICT;

-- 'GPWD' marks the file as a Gopherwood database; user_version is the schema version.
PRAGMA application_id = 1196447556;
PRAGMA user_version = 4;

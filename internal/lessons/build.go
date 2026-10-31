// Package lessons maps a boot.dev lesson to the rows of db/schema.sql, validates it, and
// writes it.
//
// What a lesson object, as boot.dev's lesson page holds it, becomes in the database: a lesson
// row, its topics, and the rows of its type's tables. Prose (the readme, quiz questions and
// answers, step descriptions, interview prompts) loses its pictures and videos; code, expected
// output, commands, requests and test values are kept exactly. Not stored: canonicalURL,
// courseImageURL, isFree, generateChallenge, videoCaptions and any solution.
package lessons

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/jobloom/gopherwood/internal/media"
)

// payloadKey names, per lesson type, the field of a lesson object that holds its readme and
// its payload.
var payloadKey = map[string]string{
	"type_code":           "lessonDataCodeOutput",
	"type_code_tests":     "lessonDataCodeTests",
	"type_choice":         "lessonDataMultipleChoice",
	"type_cli":            "lessonDataCLI",
	"type_github_checks":  "lessonDataGitHubChecks",
	"type_interview_chat": "lessonDataInterviewChat",
}

// Lesson is a row of the lesson table, without its id.
type Lesson struct {
	UUID, ChapterUUID  string
	Position           int64
	Slug, Title, Type  string
	Required           bool
	Difficulty         int64
	Readme             string
	CreatedAt, LastMod string
	CodeLastMod        sql.NullString
	SyncedAt           string
}

// Row is a row of one of the lesson's other tables, its values in tableCols order: int64 for
// INTEGER, string for TEXT, nil for NULL.
type Row struct {
	Table string
	Vals  []any
}

// Record is everything the database keeps of one lesson.
type Record struct {
	Lesson Lesson
	Rows   []Row // lesson_topic and the type's tables, parents before children
	Media  media.Stats
}

// Build turns a lesson object into a Record. The caller sets the placement
// (chapter, position, required) and synced_at.
func Build(l map[string]any) (Record, error) {
	var rec Record
	b := &builder{uuid: str(l["uuid"]), st: &rec.Media}
	r := Lesson{UUID: b.uuid, Slug: str(l["slug"]), Title: str(l["title"]), Type: str(l["type"])}
	if r.UUID == "" {
		return rec, errors.New("lesson without a uuid")
	}
	key, ok := payloadKey[r.Type]
	if !ok {
		return rec, fmt.Errorf("lesson type %q is not one the database knows", r.Type)
	}
	payload, ok := l[key].(map[string]any)
	if !ok {
		return rec, fmt.Errorf("a %s lesson without %s", r.Type, key)
	}
	d, ok := intOf(l["absoluteDifficulty"])
	if !ok || d <= 0 {
		return rec, fmt.Errorf("absoluteDifficulty %v is not a positive number", l["absoluteDifficulty"])
	}
	r.Difficulty = d
	var err error
	if r.CreatedAt, err = utcTime(str(l["createdAt"])); err != nil {
		return rec, fmt.Errorf("createdAt: %w", err)
	}
	if r.LastMod, err = utcTime(str(l["lastMod"])); err != nil {
		return rec, fmt.Errorf("lastMod: %w", err)
	}
	if s := str(l["codeLastMod"]); s != "" {
		t, err := utcTime(s)
		if err != nil {
			return rec, fmt.Errorf("codeLastMod: %w", err)
		}
		r.CodeLastMod = sql.NullString{String: t, Valid: true}
	}
	r.Readme = b.prose(str(payload["readme"]))
	rec.Lesson = r

	seen := map[string]bool{}
	for _, t := range list(l["topics"]) {
		if s := strings.TrimSpace(str(t)); s != "" && !seen[s] {
			seen[s] = true
			b.add("lesson_topic", s)
		}
	}
	switch r.Type {
	case "type_code", "type_code_tests":
		err = b.code(r.Type, payload)
	case "type_choice":
		err = b.quiz(payload)
	case "type_cli":
		err = b.cli(payload)
	case "type_github_checks":
		err = b.github(payload)
	case "type_interview_chat":
		b.add("interview_lesson", "type_interview_chat", b.prose(str(payload["studentPrompt"])), b.prose(str(payload["acceptanceCriteria"])))
	}
	if err != nil {
		return rec, err
	}
	rec.Rows = b.rows
	return rec, nil
}

type builder struct {
	uuid string
	rows []Row
	st   *media.Stats
}

// add appends a row of table; the lesson uuid comes first in every one of them.
func (b *builder) add(table string, vals ...any) {
	b.rows = append(b.rows, Row{Table: table, Vals: append([]any{b.uuid}, vals...)})
}

// prose returns s without pictures and videos.
func (b *builder) prose(s string) string {
	out, st := media.Strip(s)
	b.st.Add(st)
	return out
}

func (b *builder) code(typ string, p map[string]any) error {
	lang := str(p["progLang"])
	if lang == "" {
		return errors.New("a code lesson without progLang")
	}
	var expected any // NULL for type_code_tests
	if typ == "type_code" {
		expected = str(p["codeExpectedOutput"])
	}
	b.add("code_lesson", typ, lang, expected)
	seen := map[string]bool{}
	for i, v := range list(p["starterFiles"]) {
		f, _ := v.(map[string]any)
		name := str(f["name"])
		if name == "" || seen[name] {
			return fmt.Errorf("starter file %d: missing or repeated name %q", i, name)
		}
		seen[name] = true
		b.add("starter_file", name, int64(i), str(f["content"]), flag(f["isHidden"]), flag(f["isReadonly"]))
	}
	return nil
}

func (b *builder) quiz(p map[string]any) error {
	b.add("quiz_lesson", "type_choice", flag(p["containsCompleteDir"]))
	for qi, v := range list(p["questions"]) {
		q, _ := v.(map[string]any)
		b.add("quiz_question", int64(qi), b.prose(str(q["question"])))
		right, seen := 0, map[string]bool{}
		for ai, av := range list(q["answers"]) {
			a := str(av)
			correct := a == str(q["answer"])
			if correct {
				right++
			}
			text := b.prose(a)
			if seen[text] {
				return fmt.Errorf("question %d lists the answer %q twice", qi, text)
			}
			seen[text] = true
			b.add("quiz_answer", int64(qi), int64(ai), text, boolInt(correct))
		}
		if right != 1 {
			return fmt.Errorf("question %d has %d right answers, want 1", qi, right)
		}
	}
	return nil
}

var allowedOS = []string{"linux", "darwin", "windows"}

func (b *builder) cli(p map[string]any) error {
	cd, ok := p["cliData"].(map[string]any)
	if !ok {
		return errors.New("a command-line lesson without cliData")
	}
	b.add("cli_lesson", "type_cli", nonEmpty(str(cd["baseURLDefault"])), flag(cd["useAgentPrompt"]), flag(cd["containsCompleteDir"]))
	seenOS := map[string]bool{}
	for _, v := range list(cd["allowedOperatingSystems"]) {
		os := str(v)
		if !slices.Contains(allowedOS, os) {
			return fmt.Errorf("unknown operating system %q", os)
		}
		if !seenOS[os] {
			seenOS[os] = true
			b.add("cli_lesson_os", os)
		}
	}
	for si, v := range list(cd["steps"]) {
		s, _ := v.(map[string]any)
		cmd, isCmd := s["cliCommand"].(map[string]any)
		req, isReq := s["httpRequest"].(map[string]any)
		if isCmd == isReq {
			return fmt.Errorf("step %d is not exactly one of a command and an HTTP request", si)
		}
		step := int64(si)
		desc := b.prose(str(s["description"]))
		if isCmd {
			b.add("cli_step", step, "command", desc, flag(s["noPenaltyOnFail"]), pause(cmd["sleepAfterMs"]))
			if err := b.command(step, cmd); err != nil {
				return fmt.Errorf("step %d: %w", si, err)
			}
			continue
		}
		b.add("cli_step", step, "http", desc, flag(s["noPenaltyOnFail"]), pause(req["sleepAfterMs"]))
		if err := b.http(step, req); err != nil {
			return fmt.Errorf("step %d: %w", si, err)
		}
	}
	return nil
}

func (b *builder) command(step int64, c map[string]any) error {
	command := str(c["command"])
	if command == "" {
		return errors.New("empty command")
	}
	b.add("cli_command", step, "command", command, nullable(c["stdoutFilterTmdl"]))
	for i, v := range list(c["stdoutVariables"]) {
		m, _ := v.(map[string]any)
		b.add("cli_command_variable", step, int64(i), str(m["name"]), str(m["regex"]))
	}
	for ti, v := range list(c["tests"]) {
		t, _ := v.(map[string]any)
		kind, val, err := onlyField(t, map[string]string{
			"exitCode": "exit_code", "stdoutContainsAll": "stdout_contains_all", "stdoutContainsNone": "stdout_contains_none",
			"stdoutLinesGT": "stdout_lines_gt", "stdoutJq": "stdout_jq",
		})
		if err != nil {
			return fmt.Errorf("test %d: %w", ti, err)
		}
		test := int64(ti)
		switch kind {
		case "exit_code":
			n, ok := intOf(val)
			if !ok {
				return fmt.Errorf("test %d: exit code %v", ti, val)
			}
			b.add("cli_command_test", step, test, kind, n, nil, nil, nil)
		case "stdout_lines_gt":
			n, ok := intOf(val)
			if !ok {
				return fmt.Errorf("test %d: line count %v", ti, val)
			}
			b.add("cli_command_test", step, test, kind, nil, n, nil, nil)
		case "stdout_contains_all", "stdout_contains_none":
			b.add("cli_command_test", step, test, kind, nil, nil, nil, nil)
			for pi, s := range list(val) {
				b.add("cli_command_test_text", step, test, kind, int64(pi), str(s))
			}
		case "stdout_jq":
			jq, _ := val.(map[string]any)
			input := str(jq["inputMode"])
			if input == "" {
				input = "json"
			}
			b.add("cli_command_test", step, test, kind, nil, nil, str(jq["query"]), input)
			for ri, rv := range list(jq["expectedResults"]) {
				res, _ := rv.(map[string]any)
				typ := str(res["type"])
				bv, iv, sv, err := typedValue(typ, res["value"])
				if err != nil {
					return fmt.Errorf("test %d result %d: %w", ti, ri, err)
				}
				b.add("cli_command_test_jq_result", step, test, "stdout_jq", int64(ri), str(res["operator"]), typ, bv, iv, sv)
			}
		}
	}
	return nil
}

func (b *builder) http(step int64, h map[string]any) error {
	r, ok := h["request"].(map[string]any)
	if !ok {
		return errors.New("an HTTP step without its request")
	}
	follow := int64(1) // only an explicit false stops redirects
	if v, ok := r["followRedirects"].(bool); ok && !v {
		follow = 0
	}
	var user, pass any
	if auth, ok := r["basicAuth"].(map[string]any); ok {
		user, pass = str(auth["username"]), str(auth["password"])
	}
	jsonBody, isJSON := r["bodyJSON"].(map[string]any)
	form, isForm := r["bodyForm"].(map[string]any)
	var bodyKind, bodyJSON any
	switch {
	case isJSON && isForm:
		return errors.New("a request with both a JSON and a form body")
	case isJSON:
		enc, err := marshal(jsonBody)
		if err != nil {
			return err
		}
		bodyKind, bodyJSON = "json", string(enc)
	case isForm:
		bodyKind = "form"
	}
	b.add("cli_http_request", step, "http", str(r["method"]), str(r["fullURL"]), follow, user, pass, bodyKind, bodyJSON)
	headers, _ := r["headers"].(map[string]any)
	for i, name := range sortedKeys(headers) {
		v, err := text(headers[name])
		if err != nil {
			return fmt.Errorf("header %s: %w", name, err)
		}
		b.add("cli_http_header", step, int64(i), name, v)
	}
	for i, name := range sortedKeys(form) {
		v, err := text(form[name])
		if err != nil {
			return fmt.Errorf("form field %s: %w", name, err)
		}
		b.add("cli_http_form_field", step, "form", int64(i), name, v)
	}
	for i, v := range list(h["responseVariables"]) {
		m, _ := v.(map[string]any)
		b.add("cli_http_body_variable", step, int64(i), str(m["name"]), nonEmpty(str(m["path"])), nonEmpty(str(m["bodyRegex"])))
	}
	for i, v := range list(h["responseHeaderVariables"]) {
		m, _ := v.(map[string]any)
		b.add("cli_http_header_variable", step, int64(i), str(m["name"]), str(m["header"]), nonEmpty(str(m["regex"])))
	}
	for ti, v := range list(h["tests"]) {
		t, _ := v.(map[string]any)
		kind, val, err := onlyField(t, map[string]string{
			"statusCode": "status_code", "bodyContains": "body_contains", "bodyContainsNone": "body_contains_none",
			"headersContain": "headers_contain", "headersEqual": "headers_equal",
			"trailersContain": "trailers_contain", "trailersEqual": "trailers_equal", "jsonValue": "json_value",
		})
		if err != nil {
			return fmt.Errorf("test %d: %w", ti, err)
		}
		// status_code, text, field_name, field_value, json_path, json_operator, value_type, bool, int, string
		vals := make([]any, 10)
		switch kind {
		case "status_code":
			n, ok := intOf(val)
			if !ok {
				return fmt.Errorf("test %d: status %v", ti, val)
			}
			vals[0] = n
		case "body_contains", "body_contains_none":
			s, err := text(val)
			if err != nil {
				return fmt.Errorf("test %d: %w", ti, err)
			}
			vals[1] = s
		case "headers_contain", "headers_equal", "trailers_contain", "trailers_equal":
			kv, _ := val.(map[string]any)
			vals[2], vals[3] = str(kv["key"]), str(kv["value"])
		case "json_value":
			jv, _ := val.(map[string]any)
			op := str(jv["operator"])
			if op == "" {
				op = "eq"
			}
			typ, value, err := onlyField(jv, map[string]string{"boolValue": "bool", "intValue": "int", "stringValue": "string"})
			if err != nil {
				return fmt.Errorf("test %d: json value: %w", ti, err)
			}
			bv, iv, sv, err := typedValue(typ, value)
			if err != nil {
				return fmt.Errorf("test %d: %w", ti, err)
			}
			vals[4], vals[5], vals[6], vals[7], vals[8], vals[9] = str(jv["path"]), op, typ, bv, iv, sv
		}
		b.add("cli_http_test", append([]any{step, int64(ti), kind}, vals...)...)
	}
	return nil
}

var githubKinds = []string{"repo_exists", "submit_repo_for_course", "branch_exists", "file_contains", "pr_exists", "workflow_status", "workflow_logs_contains"}

func (b *builder) github(p map[string]any) error {
	g, ok := p["gitHubChecks"].(map[string]any)
	if !ok {
		return errors.New("a GitHub lesson without gitHubChecks")
	}
	b.add("github_lesson", "type_github_checks", flag(g["showcaseRepo"]), flag(g["containsCompleteDir"]))
	for si, v := range list(g["steps"]) {
		s, _ := v.(map[string]any)
		kind := str(s["stepType"])
		if !slices.Contains(githubKinds, kind) {
			return fmt.Errorf("step %d: unknown check %q", si, kind)
		}
		step := int64(si)
		// branch_name, file_path, pr_base_owner, pr_base_repo, pr_base_branch, pr_compare_branch, workflow_name, workflow_status
		vals := make([]any, 8)
		switch kind {
		case "branch_exists":
			vals[0] = str(dig(s, "branchExistsData", "branchName"))
		case "file_contains":
			vals[1] = str(dig(s, "fileContainsData", "filePath"))
		case "pr_exists":
			pr, _ := s["prExistsData"].(map[string]any)
			vals[2], vals[3] = nonEmpty(str(pr["baseBranchOwner"])), nonEmpty(str(pr["baseBranchRepo"]))
			vals[4], vals[5] = str(pr["baseBranchName"]), str(pr["compareBranchName"])
		case "workflow_status":
			vals[6], vals[7] = str(dig(s, "workflowStatusData", "workflowName")), str(dig(s, "workflowStatusData", "status"))
		case "workflow_logs_contains":
			vals[6] = str(dig(s, "workflowLogsContainsData", "workflowName"))
		}
		b.add("github_step", append([]any{step, kind}, vals...)...)
		switch kind {
		case "file_contains":
			for i, t := range list(dig(s, "fileContainsData", "containsAll")) {
				b.add("github_file_text", step, "file_contains", int64(i), str(t))
			}
		case "workflow_logs_contains":
			jobs, _ := dig(s, "workflowLogsContainsData", "jobs").(map[string]any)
			for _, job := range sortedKeys(jobs) {
				for i, t := range list(jobs[job]) {
					b.add("github_log_text", step, "workflow_logs_contains", job, int64(i), str(t))
				}
			}
		}
	}
	return nil
}

// ---- Values ----

// onlyField returns the one field of m, among those named in kinds, that is set, and the kind
// it stands for.
func onlyField(m map[string]any, kinds map[string]string) (string, any, error) {
	var kind string
	var val any
	for _, k := range sortedKeys(kinds) {
		if v, ok := m[k]; ok && v != nil {
			if kind != "" {
				return "", nil, fmt.Errorf("sets both %s and %s", kind, kinds[k])
			}
			kind, val = kinds[k], v
		}
	}
	if kind == "" {
		return "", nil, errors.New("sets none of the fields it may have")
	}
	return kind, val, nil
}

// typedValue puts v in the bool, int or string column that typ names.
func typedValue(typ string, v any) (bv, iv, sv any, err error) {
	switch typ {
	case "bool":
		b, ok := v.(bool)
		if !ok {
			return nil, nil, nil, fmt.Errorf("%v is not a bool", v)
		}
		return boolInt(b), nil, nil, nil
	case "int":
		n, ok := intOf(v)
		if !ok {
			return nil, nil, nil, fmt.Errorf("%v is not an int", v)
		}
		return nil, n, nil, nil
	case "string":
		s, ok := v.(string)
		if !ok {
			return nil, nil, nil, fmt.Errorf("%v is not a string", v)
		}
		return nil, nil, s, nil
	}
	return nil, nil, nil, fmt.Errorf("unknown value type %q", typ)
}

func list(v any) []any {
	l, _ := v.([]any)
	return l
}

func intOf(v any) (int64, bool) {
	switch n := v.(type) {
	case json.Number:
		i, err := n.Int64()
		return i, err == nil
	case float64:
		return int64(n), n == float64(int64(n))
	case int64:
		return n, true
	case int:
		return int64(n), true
	}
	return 0, false
}

// flag is a boolean as an INTEGER: true is 1, false and null are 0.
func flag(v any) int64 {
	b, _ := v.(bool)
	return boolInt(b)
}

func boolInt(b bool) int64 {
	if b {
		return 1
	}
	return 0
}

// nonEmpty is s, or NULL for an empty string.
func nonEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// nullable is a string value, or NULL.
func nullable(v any) any {
	if s, ok := v.(string); ok {
		return s
	}
	return nil
}

// pause is a sleepAfterMs value, or NULL when there is no pause.
func pause(v any) any {
	if n, ok := intOf(v); ok && n > 0 {
		return n
	}
	return nil
}

// text is a string value; numbers and booleans are written as JSON writes them.
func text(v any) (string, error) {
	switch x := v.(type) {
	case string:
		return x, nil
	case json.Number:
		return x.String(), nil
	case bool:
		return strconv.FormatBool(x), nil
	}
	return "", fmt.Errorf("%v is not text", v)
}

// utcTime rewrites an RFC 3339 time in UTC with a trailing Z, as the database keeps them.
func utcTime(s string) (string, error) {
	t, err := time.Parse(time.RFC3339, strings.TrimSpace(s))
	if err != nil {
		return "", fmt.Errorf("%q is not an RFC 3339 time", s)
	}
	return t.UTC().Format(time.RFC3339), nil
}

func str(v any) string {
	s, _ := v.(string)
	return s
}

func dig(v any, keys ...string) any {
	for _, k := range keys {
		m, ok := v.(map[string]any)
		if !ok {
			return nil
		}
		v = m[k]
	}
	return v
}

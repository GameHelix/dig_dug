package db

import (
	"bufio"
	"bytes"
	"context"
	"database/sql"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// crashEnv names, for the child process crash starts, the library to interrupt a write on.
const crashEnv = "GOPHERWOOD_INTERRUPTED_WRITE"

// TestHelperInterruptedWrite is not a test of its own: crash runs it in a child process. It
// starts a write on the library its environment names, too large for SQLite to keep in memory,
// so the write spills to the file before any commit, says so, and waits to be killed.
func TestHelperInterruptedWrite(t *testing.T) {
	path := os.Getenv(crashEnv)
	if path == "" {
		t.Skip("crash runs this in a child process")
	}
	d, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	d.SetMaxOpenConns(1)
	if _, err := d.Exec(`PRAGMA cache_size = 10`); err != nil {
		t.Fatal(err)
	}
	tx, err := d.Begin()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(`UPDATE course SET title = 'Changed by a write that never finished'`); err != nil {
		t.Fatal(err)
	}
	for i := range 400 {
		if _, err := tx.Exec(`INSERT INTO setting VALUES (?, ?)`, fmt.Sprintf("unfinished.%03d", i), strings.Repeat("x", 4000)); err != nil {
			t.Fatal(err)
		}
	}
	fmt.Println("spilled")
	time.Sleep(time.Minute) // killed long before this ends
}

// crash interrupts a write on the library at path as a kill would, leaving its hot journal.
func crash(t *testing.T, path string) {
	t.Helper()
	before, _ := os.ReadFile(path)
	cmd := exec.Command(os.Args[0], "-test.run=^TestHelperInterruptedWrite$")
	cmd.Env = append(os.Environ(), crashEnv+"="+path)
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	spilled := make(chan bool, 1)
	go func() {
		for sc := bufio.NewScanner(out); sc.Scan(); {
			if sc.Text() == "spilled" {
				spilled <- true
				return
			}
		}
		spilled <- false
	}()
	select {
	case ok := <-spilled:
		if !ok {
			t.Fatal("the writer ended before its write spilled to the file")
		}
	case <-time.After(time.Minute):
		t.Fatal("the writer did not spill in time")
	}
	cmd.Process.Kill()
	cmd.Wait()
	if info, err := os.Stat(path + "-journal"); err != nil || info.Size() == 0 {
		t.Fatalf("no hot journal after the crash: %v", err)
	}
	if after, _ := os.ReadFile(path); bytes.Equal(before, after) {
		t.Fatal("the interrupted write did not reach the file")
	}
}

// crashLibrary makes a small library with invented rows, and returns its path and its rows.
func crashLibrary(t *testing.T) (string, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "library.sqlite")
	d, err := Create(path)
	if err != nil {
		t.Fatal(err)
	}
	d.Close()
	raw(t, path,
		course, chapter, lesson("l1", "type_choice", 0),
		`INSERT INTO quiz_lesson VALUES ('l1', 'type_choice', 0)`,
		`INSERT INTO quiz_question VALUES ('l1', 0, 'Why write tests?')`,
		`INSERT INTO quiz_answer VALUES ('l1', 0, 0, 'To find out sooner.', 1), ('l1', 0, 1, 'For the badge.', 0)`,
		`INSERT INTO setting VALUES ('editor.font_size', '14')`,
	)
	d, err = sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	return path, dump(t, d)
}

func TestInspectRecoversAnInterruptedWrite(t *testing.T) {
	path, want := crashLibrary(t)
	crash(t, path)

	// Read-only, SQLite cannot read past the journal: this is what a plain read-only open meets.
	ro, err := readOnly(path)
	if err != nil {
		t.Fatal(err)
	}
	err = probe(ro)
	ro.Close()
	if !isReadOnlyRollback(err) {
		t.Errorf("a read-only read after the crash: err = %v, want SQLITE_READONLY_ROLLBACK", err)
	}

	d, recovered, err := Inspect(path)
	if err != nil || !recovered {
		t.Fatalf("Inspect: recovered %v, err %v", recovered, err)
	}
	defer d.Close()
	if _, err := os.Stat(path + "-journal"); err == nil {
		t.Error("the journal is still there")
	}
	if got := dump(t, d); got != want {
		t.Errorf("the rows are not as they were before the write:\n%s\nwant\n%s", got, want)
	}
	if p, err := Validate(context.Background(), d); err != nil || len(p) > 0 {
		t.Error(p, err)
	}
	if again, err := Recover(path); err != nil || again {
		t.Errorf("Recover with nothing to recover: %v, %v", again, err)
	}
}

func TestOpenRecoversAnInterruptedWrite(t *testing.T) {
	path, want := crashLibrary(t)
	crash(t, path)
	var logged bytes.Buffer
	log.SetOutput(&logged)
	defer log.SetOutput(os.Stderr)
	d, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	if !strings.Contains(logged.String(), RecoveredMessage(path)) {
		t.Errorf("Open logged %q, want the message that it recovered an interrupted write", logged.String())
	}
	if got := dump(t, d); got != want {
		t.Errorf("the rows are not as they were before the write:\n%s\nwant\n%s", got, want)
	}
}

func TestRecoverLeavesAWholeFileAlone(t *testing.T) {
	path, _ := crashLibrary(t)
	before, _ := os.ReadFile(path)
	if recovered, err := Recover(path); err != nil || recovered {
		t.Errorf("Recover: %v, %v", recovered, err)
	}
	if after, _ := os.ReadFile(path); !bytes.Equal(before, after) {
		t.Error("Recover changed a file with nothing to recover")
	}
}

package netlog

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestRotationKeepsBoundedPrivateFiles(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state", "logs")
	path := filepath.Join(dir, FileName)
	w, err := OpenWriter(path, Options{MaxBytes: 100, MaxFiles: 3})
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	line := strings.Repeat("x", 39) + "\n" // 40 bytes: two lines per file
	for i := 0; i < 20; i++ {
		if _, err := w.Write([]byte(line)); err != nil {
			t.Fatal(err)
		}
	}
	st, err := os.Stat(dir)
	if err != nil || st.Mode().Perm() != 0o700 {
		t.Fatalf("log dir mode %v (%v)", st.Mode().Perm(), err)
	}
	names, _ := filepath.Glob(path + "*")
	if len(names) != 3 {
		t.Fatalf("want 3 files, got %v", names)
	}
	for _, name := range names {
		st, err := os.Stat(name)
		if err != nil {
			t.Fatal(err)
		}
		if st.Mode().Perm() != 0o600 {
			t.Errorf("%s mode %v", name, st.Mode().Perm())
		}
		if st.Size() > 100 {
			t.Errorf("%s has %d bytes", name, st.Size())
		}
	}
	if _, err := os.Stat(path + ".3"); !os.IsNotExist(err) {
		t.Errorf("kept a fourth file: %v", err)
	}
}

func TestOpenTightensExistingPermissions(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "logs")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, FileName)
	if err := os.WriteFile(path, []byte("old\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	l, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	if st, _ := os.Stat(path); st.Mode().Perm() != 0o600 {
		t.Errorf("file mode %v", st.Mode().Perm())
	}
	if st, _ := os.Stat(dir); st.Mode().Perm() != 0o700 {
		t.Errorf("dir mode %v", st.Mode().Perm())
	}
}

func TestConcurrentWritesStayWholeLines(t *testing.T) {
	path := filepath.Join(t.TempDir(), "logs", FileName)
	l, err := OpenWith(path, Options{MaxBytes: 4096, MaxFiles: 50})
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	for g := 0; g < 8; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 100; i++ {
				l.Info("event", "goroutine", g, "i", i)
			}
		}()
	}
	wg.Wait()
	l.Close()
	lines, err := Tail(path, 10000)
	if err != nil {
		t.Fatal(err)
	}
	if len(lines) != 800 {
		t.Fatalf("got %d lines", len(lines))
	}
	seen := map[string]bool{}
	for _, line := range lines {
		var v struct {
			Msg       string `json:"msg"`
			Goroutine int    `json:"goroutine"`
			I         int    `json:"i"`
		}
		if err := json.Unmarshal([]byte(line), &v); err != nil || v.Msg != "event" {
			t.Fatalf("corrupt line %q: %v", line, err)
		}
		seen[fmt.Sprint(v.Goroutine, "/", v.I)] = true
	}
	if len(seen) != 800 {
		t.Fatalf("lost lines: %d unique", len(seen))
	}
}

func TestTailReadsAcrossRotationAndMissingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "logs", FileName)
	if lines, err := Tail(path, 5); err != nil || len(lines) != 0 {
		t.Fatalf("missing log: %v %v", lines, err)
	}
	w, err := OpenWriter(path, Options{MaxBytes: 30, MaxFiles: 5})
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 9; i++ {
		fmt.Fprintf(w, "line-%02d\n", i) // 8 bytes, 3 per file
	}
	w.Close()
	lines, err := Tail(path, 5)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(lines, ",") != "line-04,line-05,line-06,line-07,line-08" {
		t.Fatalf("tail %v", lines)
	}
}

func TestDevicePrefix(t *testing.T) {
	for in, want := range map[string]string{
		"0123456789abcdef0123": "01234567", "ABCDEF12": "abcdef12", "ab": "ab", "zz": "", "": "",
	} {
		if got := DevicePrefix(in); got != want {
			t.Errorf("DevicePrefix(%q) = %q, want %q", in, got, want)
		}
	}
}

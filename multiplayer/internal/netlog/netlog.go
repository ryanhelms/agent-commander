// Package netlog writes the device agent's network log: JSON lines from
// log/slog to a private, size-rotated file.
//
// Callers must never log credentials, request or response bodies, message
// contents or email addresses. Device identifiers go through DevicePrefix.
package netlog

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

const (
	// DefaultMaxBytes is the size at which the active file rotates.
	DefaultMaxBytes = 5 << 20
	// DefaultMaxFiles counts the active file and its rotated predecessors.
	DefaultMaxFiles = 5
	// FileName is the active log's name inside the logs directory.
	FileName = "network.log"
	// StderrFileName captures the serve process's stdout and stderr (panics).
	StderrFileName = "serve.stderr.log"
)

// Dir is the logs directory under the daemon's state directory.
func Dir(stateDir string) string { return filepath.Join(stateDir, "logs") }

// DefaultPath is the active log file under the daemon's state directory.
func DefaultPath(stateDir string) string { return filepath.Join(Dir(stateDir), FileName) }

// PrivateDir creates dir (and parents) owner-only and tightens an existing one.
func PrivateDir(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	return os.Chmod(dir, 0o700)
}

// Writer is an append-only file that rotates by size. It is safe for
// concurrent use.
type Writer struct {
	mu       sync.Mutex
	path     string
	maxBytes int64
	maxFiles int
	f        *os.File
	size     int64
}

// Options set the rotation limits. Zero values take the defaults.
type Options struct {
	MaxBytes int64
	MaxFiles int
}

// OpenWriter opens path for appending, creating its directory 0700 and the file 0600.
func OpenWriter(path string, o Options) (*Writer, error) {
	if o.MaxBytes <= 0 {
		o.MaxBytes = DefaultMaxBytes
	}
	if o.MaxFiles <= 0 {
		o.MaxFiles = DefaultMaxFiles
	}
	if err := PrivateDir(filepath.Dir(path)); err != nil {
		return nil, err
	}
	w := &Writer{path: path, maxBytes: o.MaxBytes, maxFiles: o.MaxFiles}
	if err := w.open(); err != nil {
		return nil, err
	}
	return w, nil
}

func (w *Writer) open() error {
	f, err := os.OpenFile(w.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	if err = f.Chmod(0o600); err != nil {
		f.Close()
		return err
	}
	st, err := f.Stat()
	if err != nil {
		f.Close()
		return err
	}
	w.f, w.size = f, st.Size()
	return nil
}

// Path is the active file.
func (w *Writer) Path() string { return w.path }

func rotated(path string, i int) string { return fmt.Sprintf("%s.%d", path, i) }

func (w *Writer) rotate() error {
	if w.f != nil {
		w.f.Close()
		w.f = nil
	}
	_ = os.Remove(rotated(w.path, w.maxFiles-1))
	for i := w.maxFiles - 2; i >= 1; i-- {
		if err := os.Rename(rotated(w.path, i), rotated(w.path, i+1)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	if w.maxFiles > 1 {
		if err := os.Rename(w.path, rotated(w.path, 1)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	} else {
		_ = os.Remove(w.path)
	}
	return w.open()
}

// Write appends p, rotating first when it would cross the size limit.
func (w *Writer) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.f == nil {
		if err := w.open(); err != nil {
			return 0, err
		}
	}
	if w.size > 0 && w.size+int64(len(p)) > w.maxBytes {
		if err := w.rotate(); err != nil {
			return 0, err
		}
	}
	n, err := w.f.Write(p)
	w.size += int64(n)
	return n, err
}

// Close closes the active file.
func (w *Writer) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.f == nil {
		return nil
	}
	err := w.f.Close()
	w.f = nil
	return err
}

// Logger is a JSON slog logger with the file it writes.
type Logger struct {
	*slog.Logger
	w *Writer
}

// Open starts a JSON logger at path with the default rotation limits.
func Open(path string) (*Logger, error) { return OpenWith(path, Options{}) }

// OpenWith starts a JSON logger at path with explicit rotation limits.
func OpenWith(path string, o Options) (*Logger, error) {
	w, err := OpenWriter(path, o)
	if err != nil {
		return nil, err
	}
	return &Logger{Logger: slog.New(slog.NewJSONHandler(w, &slog.HandlerOptions{Level: slog.LevelInfo})), w: w}, nil
}

// Path is the active log file.
func (l *Logger) Path() string { return l.w.Path() }

// Close closes the log file.
func (l *Logger) Close() error { return l.w.Close() }

type discard struct{}

func (discard) Enabled(context.Context, slog.Level) bool  { return false }
func (discard) Handle(context.Context, slog.Record) error { return nil }
func (d discard) WithAttrs([]slog.Attr) slog.Handler      { return d }
func (d discard) WithGroup(string) slog.Handler           { return d }

// Discard is the fallback logger when none is configured.
func Discard() *slog.Logger { return slog.New(discard{}) }

// DevicePrefix shortens a device fingerprint to at most 8 hex characters.
func DevicePrefix(id string) string {
	id = strings.ToLower(id)
	n := 0
	for n < len(id) && n < 8 && strings.IndexByte("0123456789abcdef", id[n]) >= 0 {
		n++
	}
	return id[:n]
}

const tailWindow = 512 << 10

// Tail returns up to n of the last lines across path and its rotated
// predecessors, oldest first. A missing log yields no lines.
func Tail(path string, n int) ([]string, error) {
	if n <= 0 {
		return []string{}, nil
	}
	var out []string
	for i := 0; len(out) < n; i++ {
		name := path
		if i > 0 {
			name = rotated(path, i)
		}
		lines, err := lastLines(name, n-len(out))
		if errors.Is(err, os.ErrNotExist) {
			if i == 0 {
				continue
			}
			break
		}
		if err != nil {
			return nil, err
		}
		out = append(lines, out...)
		if i >= 64 {
			break
		}
	}
	if out == nil {
		out = []string{}
	}
	return out, nil
}

func lastLines(name string, n int) ([]string, error) {
	f, err := os.Open(name)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	start := max(st.Size()-tailWindow, 0)
	if _, err = f.Seek(start, io.SeekStart); err != nil {
		return nil, err
	}
	data, err := io.ReadAll(io.LimitReader(f, tailWindow))
	if err != nil {
		return nil, err
	}
	if start > 0 {
		// Drop the partial first line.
		if i := bytes.IndexByte(data, '\n'); i >= 0 {
			data = data[i+1:]
		}
	}
	data = bytes.TrimRight(data, "\n")
	if len(data) == 0 {
		return nil, nil
	}
	all := strings.Split(string(data), "\n")
	if len(all) > n {
		all = all[len(all)-n:]
	}
	return all, nil
}

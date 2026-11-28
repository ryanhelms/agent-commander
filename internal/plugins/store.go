package plugins

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

const (
	installedName    = "installed.json"
	maxInstalledSize = 4 << 20
	maxPackageBytes  = 1 << 30
	maxPackageFiles  = 100_000
)

// Record is one installed plugin as frozen at install time.
type Record struct {
	ID          string   `json:"id"`
	Version     string   `json:"version"`
	Name        string   `json:"name"`
	Description string   `json:"description,omitempty"`
	Command     []string `json:"command"`
	// Program is the absolute path a bare command resolved to at install. The
	// service falls back to it when its own PATH lacks the program, as when
	// the app starts the service without a login shell's PATH.
	Program        string          `json:"program,omitempty"`
	EnvAllow       []string        `json:"env_allow,omitempty"`
	SettingsSchema json.RawMessage `json:"settings_schema,omitempty"`
	Digest         string          `json:"digest"`
	InstalledAt    time.Time       `json:"installed_at"`
	Tools          []ToolRecord    `json:"tools"`
}

// ToolRecord freezes a contributed tool's schema as the plugin reported it.
type ToolRecord struct {
	ID          string          `json:"id"`
	Version     int             `json:"version"`
	MCPTool     string          `json:"mcp_tool"`
	Description string          `json:"description"`
	InputSchema json.RawMessage `json:"input_schema"`
}

type installedFile struct {
	Schema  int      `json:"schema"`
	Plugins []Record `json:"plugins"`
}

// Root is the directory that holds every installed plugin.
func Root(stateDir string) string { return filepath.Join(stateDir, "plugins") }

// Dir is where one plugin version's files live.
func (r Record) Dir(stateDir string) string { return filepath.Join(Root(stateDir), r.ID, r.Version) }

// DataDir is the plugin's own writable directory, kept across upgrades.
func (r Record) DataDir(stateDir string) string { return filepath.Join(Root(stateDir), r.ID, "data") }

// LogPath receives the plugin's stderr.
func (r Record) LogPath(stateDir string) string {
	return filepath.Join(Root(stateDir), r.ID, "plugin.log")
}

// List returns the installed plugins in ID order.
func List(stateDir string) ([]Record, error) {
	path := filepath.Join(Root(stateDir), installedName)
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
		return nil, fmt.Errorf("%s must be a private regular file", installedName)
	}
	raw, err := readLimited(path, maxInstalledSize)
	if err != nil {
		return nil, err
	}
	var file installedFile
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&file); err != nil || file.Schema != 1 {
		return nil, fmt.Errorf("invalid %s", installedName)
	}
	slices.SortFunc(file.Plugins, func(a, b Record) int { return strings.Compare(a.ID, b.ID) })
	return file.Plugins, nil
}

func saveInstalled(stateDir string, records []Record) error {
	slices.SortFunc(records, func(a, b Record) int { return strings.Compare(a.ID, b.ID) })
	if records == nil {
		records = []Record{}
	}
	raw, err := json.MarshalIndent(installedFile{Schema: 1, Plugins: records}, "", "  ")
	if err != nil {
		return err
	}
	return writePrivate(filepath.Join(Root(stateDir), installedName), append(raw, '\n'))
}

func ensurePrivateDir(path string) error {
	if err := os.MkdirAll(path, 0o700); err != nil {
		return err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("%s must be a directory", path)
	}
	return os.Chmod(path, 0o700)
}

// writePrivate replaces path atomically with an owner-only file.
func writePrivate(path string, data []byte) error {
	if err := ensurePrivateDir(filepath.Dir(path)); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

func readLimited(path string, limit int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	raw, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(raw)) > limit {
		return nil, fmt.Errorf("%s is too large", filepath.Base(path))
	}
	return raw, nil
}

// Digest hashes a package tree: each entry's relative path, kind, executable
// bit and content (or link target), in lexical order. Symlinks must resolve
// inside the tree; anything else (devices, sockets) is refused.
func Digest(root string) (string, error) {
	hash := sha256.New()
	var total int64
	files := 0
	err := walkPackage(root, func(rel string, info fs.FileInfo, path string) error {
		files++
		if files > maxPackageFiles {
			return fmt.Errorf("package has more than %d entries", maxPackageFiles)
		}
		switch mode := info.Mode(); {
		case mode.IsDir():
			fmt.Fprintf(hash, "d\x00%s\x00", rel)
		case mode&fs.ModeSymlink != 0:
			target, err := os.Readlink(path)
			if err != nil {
				return err
			}
			fmt.Fprintf(hash, "l\x00%s\x00%s\x00", rel, target)
		default:
			total += info.Size()
			if total > maxPackageBytes {
				return errors.New("package exceeds 1 GiB")
			}
			fmt.Fprintf(hash, "f\x00%s\x00%t\x00%d\x00", rel, mode.Perm()&0o111 != 0, info.Size())
			file, err := os.Open(path)
			if err != nil {
				return err
			}
			_, err = io.Copy(hash, file)
			file.Close()
			if err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return "", err
	}
	return "sha256:" + hex.EncodeToString(hash.Sum(nil)), nil
}

// walkPackage visits every entry below root in lexical order, rejecting
// special files and symlinks that escape the tree.
func walkPackage(root string, visit func(rel string, info fs.FileInfo, path string) error) error {
	root, err := filepath.Abs(root)
	if err != nil {
		return err
	}
	return filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if path == root {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		mode := info.Mode()
		switch {
		case mode.IsDir(), mode.IsRegular():
		case mode&fs.ModeSymlink != 0:
			target, err := os.Readlink(path)
			if err != nil {
				return err
			}
			resolved := target
			if !filepath.IsAbs(target) {
				resolved = filepath.Join(filepath.Dir(path), target)
			}
			if inside, _ := filepath.Rel(root, filepath.Clean(resolved)); filepath.IsAbs(target) || inside == ".." || strings.HasPrefix(inside, "../") {
				return fmt.Errorf("symlink %s points outside the package", rel)
			}
		default:
			return fmt.Errorf("%s is not a regular file, directory or symlink", rel)
		}
		return visit(filepath.ToSlash(rel), info, path)
	})
}

// copyPackage copies src into an empty dst, preserving the executable bit and
// relative symlinks. Files become owner-only.
func copyPackage(src, dst string) error {
	return walkPackage(src, func(rel string, info fs.FileInfo, path string) error {
		target := filepath.Join(dst, filepath.FromSlash(rel))
		switch mode := info.Mode(); {
		case mode.IsDir():
			return os.Mkdir(target, 0o700)
		case mode&fs.ModeSymlink != 0:
			link, err := os.Readlink(path)
			if err != nil {
				return err
			}
			return os.Symlink(link, target)
		default:
			perm := os.FileMode(0o600)
			if mode.Perm()&0o111 != 0 {
				perm = 0o700
			}
			in, err := os.Open(path)
			if err != nil {
				return err
			}
			defer in.Close()
			out, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, perm)
			if err != nil {
				return err
			}
			if _, err := io.Copy(out, in); err != nil {
				out.Close()
				return err
			}
			return out.Close()
		}
	})
}

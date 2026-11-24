package catalog

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

var packageVersion = regexp.MustCompile(`^[0-9][A-Za-z0-9.+-]*$`)

const npmVersionNumber = `(?:0|[1-9][0-9]*)`
const npmPrereleasePart = `(?:` + npmVersionNumber + `|[0-9]*[A-Za-z-][0-9A-Za-z-]*)`

var npmVersion = regexp.MustCompile(`^` + npmVersionNumber + `\.` + npmVersionNumber + `\.` + npmVersionNumber +
	`(?:-` + npmPrereleasePart + `(?:\.` + npmPrereleasePart + `)*)?(?:\+[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*)?$`)
var npmName = regexp.MustCompile(`^(@[a-z0-9._-]+/)?[a-z0-9][a-z0-9._-]*$`)
var pythonName = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._-]*$`)
var pythonLockLine = regexp.MustCompile(`^([a-zA-Z0-9][a-zA-Z0-9._-]*)==([0-9][A-Za-z0-9.+-]*)[ \t]+--hash=sha256:[a-fA-F0-9]{64}([ \t]+--hash=sha256:[a-fA-F0-9]{64})*$`)
var pythonSeparators = regexp.MustCompile(`[-_.]+`)

func exactPackage(manager, spec string) (string, string, error) {
	at := strings.LastIndex(spec, "@")
	width := 1
	namePattern, versionPattern := npmName, npmVersion
	if manager == "python" {
		namePattern, versionPattern = pythonName, packageVersion
		if equals := strings.Index(spec, "=="); equals >= 0 {
			at, width = equals, 2
		}
	}
	if at <= 0 || !namePattern.MatchString(spec[:at]) || !versionPattern.MatchString(spec[at+width:]) {
		return "", "", errors.New("catalog package distribution requires an exact name and version")
	}
	return spec[:at], spec[at+width:], nil
}

func matchPackageRelease(manager, catalogSpec, signedSpec string) bool {
	signedName, signedVersion, err := exactPackage(manager, signedSpec)
	if err != nil {
		return false
	}
	catalogName, catalogVersion, err := exactPackage(manager, catalogSpec)
	if err != nil {
		// ACP registry entries can publish just a package name. Never treat a
		// tag, range, URL, or non-matching name as permission to choose a pin.
		catalogName = catalogSpec
		validName := npmName
		if manager == "python" {
			validName = pythonName
		}
		if !validName.MatchString(catalogName) {
			return false
		}
	} else if catalogVersion != signedVersion {
		return false
	}
	if manager == "python" {
		return canonicalPythonName(catalogName) == canonicalPythonName(signedName)
	}
	return catalogName == signedName
}

func canonicalPythonName(name string) string {
	return pythonSeparators.ReplaceAllString(strings.ToLower(name), "-")
}

func installPackage(ctx context.Context, dir, command, manager, spec string) error {
	name, version, err := exactPackage(manager, spec)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	switch manager {
	case "npm":
		if filepath.Dir(command) != filepath.Join(dir, "node_modules", ".bin") {
			return errors.New("npm bundle executable must name a node_modules/.bin launcher")
		}
		if err := verifyNPMLock(dir, name, version); err != nil {
			return err
		}
		for _, reserved := range []string{".npmrc", "node_modules", ".cache"} {
			if _, err := os.Lstat(filepath.Join(dir, reserved)); !errors.Is(err, os.ErrNotExist) {
				return fmt.Errorf("npm bundle must not contain %s", reserved)
			}
		}
		if err := runInstaller(ctx, dir, "npm", "ci", "--offline", "--ignore-scripts", "--no-audit", "--no-fund",
			"--userconfig", filepath.Join(filepath.Dir(dir), "empty-npmrc"), "--globalconfig=/dev/null", "--cache", filepath.Join(dir, ".cache")); err != nil {
			return err
		}
		var installed struct{ Name, Version string }
		raw, err := os.ReadFile(filepath.Join(dir, "node_modules", name, "package.json"))
		if err != nil || json.Unmarshal(raw, &installed) != nil || installed.Name != name || installed.Version != version {
			return errors.New("installed npm package identity does not match the signed release")
		}
	case "python":
		if filepath.Dir(command) != filepath.Join(dir, "venv", "bin") {
			return errors.New("Python bundle executable must name a venv/bin launcher")
		}
		if _, err := os.Lstat(filepath.Join(dir, "venv")); !errors.Is(err, os.ErrNotExist) {
			return errors.New("Python bundle must not contain an existing virtual environment")
		}
		if err := verifyPythonLock(dir, name, version); err != nil {
			return err
		}
		if err := runInstaller(ctx, dir, "python3", "-I", "-m", "venv", filepath.Join(dir, "venv")); err != nil {
			return err
		}
		python := filepath.Join(dir, "venv", "bin", "python")
		if err := runInstaller(ctx, dir, python, "-I", "-m", "pip", "--isolated",
			"install", "--no-index", "--only-binary=:all:", "--require-hashes", "--find-links", filepath.Join(dir, "wheels"),
			"-r", filepath.Join(dir, "requirements.txt")); err != nil {
			return err
		}
		if err := runInstaller(ctx, dir, python, "-I", "-c", `import sys; from importlib.metadata import distribution; d = distribution(sys.argv[1]); sys.exit(0 if d.version == sys.argv[2] and any(e.group == "console_scripts" and e.name == sys.argv[3] for e in d.entry_points) else 1)`,
			name, version, filepath.Base(command)); err != nil {
			return errors.New("installed Python distribution or console script does not match the signed release")
		}
	default:
		return errors.New("unsupported package manager")
	}
	resolved, err := filepath.EvalSymlinks(command)
	if err != nil {
		return err
	}
	canonicalDir, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return err
	}
	relative, err := filepath.Rel(canonicalDir, resolved)
	if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(os.PathSeparator)) {
		return errors.New("package executable resolves outside the verified installation")
	}
	_, err = exec.LookPath(command)
	return err
}

func runInstaller(ctx context.Context, dir, command string, args ...string) error {
	cmd := exec.CommandContext(ctx, command, args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "PIP_CONFIG_FILE=/dev/null", "PIP_DISABLE_PIP_VERSION_CHECK=1")
	if _, err := cmd.Output(); err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) && len(exit.Stderr) != 0 {
			detail := strings.TrimSpace(string(exit.Stderr[:min(len(exit.Stderr), 2048)]))
			return fmt.Errorf("offline %s installation: %w: %s", filepath.Base(command), err, detail)
		}
		return fmt.Errorf("offline %s installation: %w", filepath.Base(command), err)
	}
	return nil
}

func verifyNPMLock(dir, name, version string) error {
	data, err := os.ReadFile(filepath.Join(dir, "package-lock.json"))
	if err != nil {
		return err
	}
	var lock struct {
		LockfileVersion int
		Packages        map[string]struct {
			Version, Resolved, Integrity string
			Link                         bool
		}
	}
	if err := json.Unmarshal(data, &lock); err != nil || lock.LockfileVersion != 3 || lock.Packages["node_modules/"+name].Version != version {
		return errors.New("npm lockfile does not pin the selected package and exact version")
	}
	for location, p := range lock.Packages {
		if location == "" {
			continue
		}
		tarball, local := strings.CutPrefix(p.Resolved, "file:packages/")
		if !strings.HasPrefix(location, "node_modules/") || filepath.ToSlash(filepath.Clean(location)) != location ||
			p.Link || !npmVersion.MatchString(p.Version) || !strings.HasPrefix(p.Integrity, "sha512-") ||
			!local || filepath.Base(tarball) != tarball || !strings.HasSuffix(tarball, ".tgz") {
			return errors.New("npm lockfile must pin each dependency to a local, hashed package tarball")
		}
	}
	return nil
}

func verifyPythonLock(dir, name, version string) error {
	data, err := os.ReadFile(filepath.Join(dir, "requirements.txt"))
	if err != nil {
		return err
	}
	found := false
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := pythonLockLine.FindStringSubmatch(line)
		if parts == nil {
			return errors.New("Python lockfile must pin and hash every wheel without package sources or extra options")
		}
		if canonicalPythonName(parts[1]) == canonicalPythonName(name) && parts[2] == version {
			found = true
		}
	}
	if !found {
		return errors.New("Python lockfile does not pin the selected package and exact version")
	}
	return nil
}

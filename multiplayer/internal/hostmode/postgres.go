package hostmode

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

const homebrewPostgres = "/opt/homebrew/opt/postgresql@17/bin"

// postgresBin finds the PostgreSQL server binaries: COMMANDER_PG_BIN, the
// app bundle, then the platform's package locations and PATH.
func postgresBin() string {
	if bin := os.Getenv("COMMANDER_PG_BIN"); bin != "" {
		return bin
	}
	if exe, err := os.Executable(); err == nil {
		// The app installs commander-relay in Contents/MacOS.
		bin := filepath.Join(filepath.Dir(exe), "..", "Resources", "postgres", "bin")
		if _, err := os.Stat(filepath.Join(bin, "postgres")); err == nil {
			return bin
		}
	}
	if runtime.GOOS == "darwin" {
		return homebrewPostgres
	}
	for _, bin := range packagedPostgres() {
		if serverBinaries(bin) {
			return bin
		}
	}
	if initdb, err := exec.LookPath("initdb"); err == nil && serverBinaries(filepath.Dir(initdb)) {
		return filepath.Dir(initdb)
	}
	return "/usr/lib/postgresql/17/bin"
}

func serverBinaries(bin string) bool {
	for _, name := range []string{"postgres", "initdb"} {
		if info, err := os.Stat(filepath.Join(bin, name)); err != nil || info.IsDir() {
			return false
		}
	}
	return true
}

// packagedPostgres lists Debian, Ubuntu and RHEL server directories, newest
// major version first.
func packagedPostgres() []string {
	type candidate struct {
		dir     string
		version int
	}
	var found []candidate
	for _, pattern := range []string{"/usr/lib/postgresql/*/bin", "/usr/pgsql-*/bin"} {
		matches, _ := filepath.Glob(pattern)
		for _, dir := range matches {
			name := filepath.Base(filepath.Dir(dir))
			version, err := strconv.Atoi(strings.TrimPrefix(name, "pgsql-"))
			if err == nil {
				found = append(found, candidate{dir, version})
			}
		}
	}
	slices.SortStableFunc(found, func(a, b candidate) int { return b.version - a.version })
	dirs := make([]string, len(found))
	for i, c := range found {
		dirs[i] = c.dir
	}
	return dirs
}

func initCluster(ctx context.Context, bin, dataDir string, settings []string) error {
	if _, err := os.Stat(filepath.Join(dataDir, "PG_VERSION")); !errors.Is(err, os.ErrNotExist) {
		return err
	}
	// Publish the complete cluster in one rename so a cancelled first run is retryable.
	stage, err := os.MkdirTemp(filepath.Dir(dataDir), ".initdb-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(stage)
	cmd := exec.CommandContext(ctx, filepath.Join(bin, "initdb"), "-D", stage, "-U", "commander",
		"--auth-local=trust", "--auth-host=reject", "--encoding=UTF8", "--no-locale")
	cmd.Env = postgresEnv()
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("initialize host PostgreSQL: %w\n%s", err, output)
	}
	// initdb accepts -c only from PostgreSQL 16, so persist the settings in the
	// cluster's configuration file, which every supported version reads.
	conf, err := os.OpenFile(filepath.Join(stage, "postgresql.conf"), os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		return err
	}
	_, err = conf.WriteString(configLines(settings))
	if err = errors.Join(err, conf.Close()); err != nil {
		return err
	}
	return os.Rename(stage, dataDir)
}

// configLines turns "-c name=value" arguments into postgresql.conf lines.
func configLines(settings []string) string {
	var lines strings.Builder
	lines.WriteString("\n# Agent Commander host relay\n")
	for i := 1; i < len(settings); i += 2 {
		name, value, _ := strings.Cut(settings[i], "=")
		lines.WriteString(name + " = '" + strings.ReplaceAll(value, "'", "''") + "'\n")
	}
	return lines.String()
}

// Postgres owns the host's postmaster and its private Unix-socket connection pool.
type Postgres struct {
	Pool *pgxpool.Pool

	process *os.Process
	done    chan struct{}
	waitErr error
}

func (p *Postgres) Done() <-chan struct{} { return p.done }

// Err waits for the child to exit and returns its exit status.
func (p *Postgres) Err() error {
	<-p.done
	return p.waitErr
}

func (p *Postgres) Close() error {
	// SIGINT requests PostgreSQL's fast, checkpointed shutdown.
	err := p.process.Signal(os.Interrupt)
	p.Pool.Close()
	if err != nil && !errors.Is(err, os.ErrProcessDone) {
		return err
	}
	return p.Err()
}

func postgresPool(ctx context.Context, socketDir string) (*pgxpool.Pool, error) {
	// Set the socket path directly. pgx treats commas in a DSN's host as failover targets.
	cfg, err := pgxpool.ParseConfig("host=/tmp port=5432 user=commander dbname=postgres sslmode=disable")
	if err != nil {
		return nil, err
	}
	cfg.ConnConfig.Host = socketDir
	return pgxpool.NewWithConfig(ctx, cfg)
}

// StartPostgres starts or initializes the database and waits until the pool can
// query it. The caller owns Close after startup succeeds.
func StartPostgres(ctx context.Context, dir string) (*Postgres, error) {
	dir, err := filepath.Abs(dir)
	if err != nil {
		return nil, err
	}
	bin := postgresBin()
	if !serverBinaries(bin) {
		return nil, fmt.Errorf("PostgreSQL server binaries not found in %s; install PostgreSQL 15 or newer, or set COMMANDER_PG_BIN to its bin directory", bin)
	}
	dataDir := filepath.Join(dir, "postgres")
	socketDir := filepath.Join(dir, "run")
	if err := os.MkdirAll(socketDir, 0700); err != nil {
		return nil, err
	}
	// Both initdb and postgres accept -c settings. Persist the private listener
	// defaults and enforce them on each start, including after moving the host directory.
	sockets := `unix_socket_directories="` + strings.ReplaceAll(socketDir, `"`, `""`) + `"`
	settings := []string{"-c", "listen_addresses=", "-c", sockets, "-c", "unix_socket_permissions=0700"}
	if err := initCluster(ctx, bin, dataDir, settings); err != nil {
		return nil, err
	}

	pool, err := postgresPool(ctx, socketDir)
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(filepath.Join(bin, "postgres"), "-D", dataDir, "-p", "5432")
	cmd.Args = append(cmd.Args, settings...)
	cmd.Env = postgresEnv()
	cmd.Stdout, cmd.Stderr = os.Stderr, os.Stderr
	if err := cmd.Start(); err != nil {
		pool.Close()
		return nil, err
	}
	p := &Postgres{Pool: pool, process: cmd.Process, done: make(chan struct{})}
	go func() {
		p.waitErr = cmd.Wait()
		close(p.done)
	}()

	readyCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	tick := time.NewTicker(50 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-p.done:
			pool.Close()
			return nil, fmt.Errorf("PostgreSQL stopped during startup: %s", cmd.ProcessState)
		case <-readyCtx.Done():
			_ = p.Close()
			return nil, fmt.Errorf("wait for host PostgreSQL: %w", readyCtx.Err())
		case <-tick.C:
			// An existing relay can own the same cluster. Only accept our own child.
			pidFile, err := os.ReadFile(filepath.Join(dataDir, "postmaster.pid"))
			pid, _, _ := strings.Cut(string(pidFile), "\n")
			if err == nil && pid == strconv.Itoa(cmd.Process.Pid) && pool.Ping(readyCtx) == nil {
				return p, nil
			}
		}
	}
}

// postgresEnv sets a valid locale. On macOS the postmaster refuses to start
// ("postmaster became multithreaded during startup") without LC_ALL, which a
// launchd agent does not provide. Minimal Linux hosts and images often lack
// en_US, but glibc and musl both provide C.UTF-8.
func postgresEnv() []string {
	env := os.Environ()
	if os.Getenv("LC_ALL") == "" {
		locale := "C.UTF-8"
		if runtime.GOOS == "darwin" {
			locale = "en_US.UTF-8"
		}
		env = append(env, "LC_ALL="+locale)
	}
	return env
}

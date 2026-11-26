package hostmode

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

const homebrewPostgres = "/opt/homebrew/opt/postgresql@17/bin"

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
	return homebrewPostgres
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
	cmd.Args = append(cmd.Args, settings...)
	cmd.Env = postgresEnv()
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("initialize host PostgreSQL: %w\n%s", err, output)
	}
	return os.Rename(stage, dataDir)
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
// launchd agent does not provide.
func postgresEnv() []string {
	env := os.Environ()
	if os.Getenv("LC_ALL") == "" {
		env = append(env, "LC_ALL=en_US.UTF-8")
	}
	return env
}

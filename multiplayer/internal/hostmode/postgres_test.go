package hostmode

import (
	"context"
	"errors"
	"net"
	"path/filepath"
	"testing"
	"time"
)

func TestPostgresPoolUsesOnlyHostSocket(t *testing.T) {
	t.Setenv("PGHOST", "localhost,example.invalid")
	t.Setenv("PGPORT", "6000")
	t.Setenv("PGSERVICE", "")
	socketDir := filepath.Join(t.TempDir(), "Example, Inc", "run")
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	pool, err := postgresPool(ctx, socketDir)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if len(pool.Config().ConnConfig.Fallbacks) != 0 {
		t.Fatal("host pool has fallback connections")
	}
	var opErr *net.OpError
	err = pool.Ping(ctx)
	if !errors.As(err, &opErr) || opErr.Net != "unix" || opErr.Addr.String() != filepath.Join(socketDir, ".s.PGSQL.5432") {
		t.Fatalf("expected a dial to the host's Unix socket, got %v", err)
	}
}

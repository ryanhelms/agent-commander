package main

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"net/http"
	"os"
	"slices"
	"testing"
)

// The Darwin system verifier cannot load a process-local SSL_CERT_FILE. In
// this test executable only, trust the private fixture CA for CLI subprocesses.
func TestCatalogFixtureCLI(t *testing.T) {
	ca := os.Getenv("COMMANDER_TEST_CATALOG_CA")
	if ca == "" {
		t.Skip("used by the signed catalog notice verification driver")
	}
	index := slices.Index(os.Args, "--")
	if index < 0 || index+1 >= len(os.Args) || os.Args[index+1] != "catalog" {
		t.Fatal("expected -- catalog <command>")
	}
	cert, err := os.ReadFile(ca)
	if err != nil {
		t.Fatal(err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(cert) {
		t.Fatal("invalid fixture root")
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig = &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}
	http.DefaultTransport = transport
	if err := run(os.Args[index+1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	os.Exit(0) // Keep the Go test harness PASS banner off the CLI JSON pipe.
}

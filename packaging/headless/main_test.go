package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"io"
	"os"
	"path/filepath"
	"testing"
)

func TestPackIsReproducibleAndComplete(t *testing.T) {
	a, err := pack([]byte("binary"), "v1.2.3")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := pack([]byte("binary"), "v1.2.3")
	if !bytes.Equal(a, b) {
		t.Fatal("two packs of the same input differ")
	}
	gz, err := gzip.NewReader(bytes.NewReader(a))
	if err != nil {
		t.Fatal(err)
	}
	tr := tar.NewReader(gz)
	got := map[string]int64{}
	for {
		h, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		got[h.Name] = h.Mode
		if h.Uid != 0 || h.Gid != 0 || h.ModTime.Unix() != 0 {
			t.Errorf("%s has owner %d:%d or time %v", h.Name, h.Uid, h.Gid, h.ModTime)
		}
	}
	if got[top+"/agentctl"] != 0755 || got[top+"/VERSION"] != 0644 || len(got) != 4 {
		t.Fatalf("unexpected members %v", got)
	}
}

func TestCheckBinaryRefusesNonLinux(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agentctl")
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"), 0755); err != nil {
		t.Fatal(err)
	}
	if _, err := checkBinary(path, "amd64", "v1.0.0"); err == nil {
		t.Fatal("expected a shell script to be refused")
	}
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := checkBinary(self, "amd64", "v1.0.0"); err == nil {
		t.Fatal("expected the test binary to be refused: wrong OS or not agentctl")
	}
}

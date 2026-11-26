package hostmode

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"testing"
)

func TestHostConfig(t *testing.T) {
	dir := t.TempDir()
	cfg := Config{
		Name: "Office relay", Hostnames: []string{"office.example.test", "127.0.0.1"},
		Issuer: "https://issuer.example.test", ClientID: "commander",
		AllowedEmails: []string{"guest@example.test", "admin@example.test"},
		Admins:        []string{"ADMIN@example.test", "owner@example.test"},
	}
	if err := InitConfig(dir, cfg); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "host.json")
	checkMode(t, dir, 0700)
	checkMode(t, path, 0600)
	got, err := ReadConfig(dir)
	if err != nil {
		t.Fatal(err)
	}
	cfg.Listen = ":443"
	if !reflect.DeepEqual(got, cfg) {
		t.Fatalf("host config = %+v, want %+v", got, cfg)
	}
	if want := []string{"guest@example.test", "admin@example.test", "owner@example.test"}; !slices.Equal(got.PermittedEmails(), want) {
		t.Fatalf("permitted emails = %v, want %v", got.PermittedEmails(), want)
	}
	cfg.Name = "Replacement"
	if err := InitConfig(dir, cfg); !errors.Is(err, os.ErrExist) {
		t.Fatalf("second init = %v, want existing config", err)
	}
	got, err = ReadConfig(dir)
	if err != nil || got.Name != "Office relay" {
		t.Fatalf("second init changed host config: %+v (%v)", got, err)
	}
	cfg.Admins = nil
	raw, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err = ReadConfig(dir); err == nil {
		t.Fatal("read a host config with no initial admin")
	}
}

func checkMode(t *testing.T, path string, want os.FileMode) {
	t.Helper()
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != want {
		t.Errorf("permissions on %s = %o, want %o", path, st.Mode().Perm(), want)
	}
}

func TestUpdateConfig(t *testing.T) {
	dir := t.TempDir()
	cfg := Config{
		Name: "Relay", Listen: ":8443", Hostnames: []string{"relay.example.test"},
		Issuer: "https://issuer.example.test", ClientID: "commander", Admins: []string{"admin@example.test"},
	}
	if err := InitConfig(dir, cfg); err != nil {
		t.Fatal(err)
	}
	if err := UpdateConfig(dir, []string{"agent-relay.tail.internal", "100.64.0.7", "RELAY.example.test"}, ":443"); err != nil {
		t.Fatal(err)
	}
	got, err := ReadConfig(dir)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"relay.example.test", "agent-relay.tail.internal", "100.64.0.7"}
	if !slices.Equal(got.Hostnames, want) || got.Listen != ":443" || got.Name != "Relay" {
		t.Fatalf("updated config = %+v", got)
	}
	checkMode(t, filepath.Join(dir, "host.json"), 0600)
	if err := UpdateConfig(dir, []string{"bad name"}, ""); err == nil {
		t.Fatal("accepted an invalid hostname")
	}
	if got, _ = ReadConfig(dir); !slices.Equal(got.Hostnames, want) {
		t.Fatalf("a refused update changed the config: %v", got.Hostnames)
	}
	if err := UpdateConfig(t.TempDir(), []string{"x.example.test"}, ""); err == nil {
		t.Fatal("updated a missing config")
	}
}

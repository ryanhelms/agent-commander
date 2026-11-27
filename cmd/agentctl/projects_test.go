package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestProjectCLI(t *testing.T) {
	t.Chdir(t.TempDir())
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	checkout := filepath.Join(cwd, "nested checkout")
	if err := os.Mkdir(checkout, 0700); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name, method, path, open string
		args                     []string
		want                     map[string]string
	}{
		{"list", "GET", "/v1/projects", "", []string{"project", "list"}, nil},
		{"open working directory", "POST", "/v1/projects", "project", []string{"project", "open", "--open"}, map[string]string{"path": cwd}},
		{"open explicit directory", "POST", "/v1/projects", "", []string{"project", "open", "nested checkout"}, map[string]string{"path": checkout}},
		{"run working directory", "POST", "/v1/runs", "run", []string{"run", "--open", "--cwd", "Inspect the folder"}, map[string]string{
			"path": cwd, "project": filepath.Base(cwd), "task": "Inspect the folder", "client": "claude",
		}},
		{"explicit directory and literal task option", "POST", "/v1/runs", "", []string{"run", "--client", "codex", checkout, "Explain", "--open"}, map[string]string{
			"path": checkout, "project": "nested checkout", "task": "Explain --open", "client": "codex",
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			args, open := cockpitLaunchArgs(tc.args)
			method, path, input, err := operation(args)
			if err != nil || method != tc.method || path != tc.path || open != tc.open {
				t.Fatalf("got %q %q open=%q err=%v", method, path, open, err)
			}
			if input == nil && tc.want == nil {
				return
			}
			if !reflect.DeepEqual(input, tc.want) {
				t.Fatalf("got %#v, want %#v", input, tc.want)
			}
		})
	}
}

func TestProjectCockpitResultURL(t *testing.T) {
	const id = "0123456789abcdef0123456789abcdef"
	for kind, prefix := range map[string]string{"run": "r-", "project": "p-"} {
		got, err := cockpitResultURL(kind, []byte(`{"id":"`+prefix+id+`"}`))
		if want := "agentcommander://" + kind + "/" + prefix + id; err != nil || got != want {
			t.Fatalf("got %q, %v; want %q", got, err, want)
		}
	}
	if _, err := cockpitResultURL("run", []byte(`{"id":"p-`+id+`"}`)); err == nil {
		t.Fatal("run opening accepted a project ID")
	}
	if _, err := cockpitResultURL("run", []byte(`{"id":"r-value?path=/other"}`)); err == nil {
		t.Fatal("run opening accepted a URL fragment as an ID")
	}
}

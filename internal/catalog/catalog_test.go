package catalog

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
)

type testTransport func(*http.Request) (*http.Response, error)

func (f testTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	return f(req)
}

func TestPublishedDistributionMetadataStaysAttributed(t *testing.T) {
	const body = `{
		"version":"1.0.0",
		"agents":[{"id":"fixture","name":"Fixture Agent","version":"2.1.0","authors":["Claimed publisher"],
			"publisher_verification":"verified",
			"distribution":{
				"binary":{"darwin-aarch64":{"archive":"https://example.test/tool.tgz","cmd":"./tool","args":["serve"],"sha256":"example"}},
				"npx":{"package":"@fixture/agent@2.1.0","args":["--acp"]},
				"uvx":{"package":"fixture-agent==2.1.0","env":{"MODE":"acp"}}
			}
		}]
	}`
	client := &http.Client{Transport: testTransport(func(req *http.Request) (*http.Response, error) {
		if req.Method != http.MethodGet || req.Header.Get("Accept") != "application/json" {
			t.Fatalf("unexpected catalog request: %s %v", req.Method, req.Header)
		}
		return &http.Response{StatusCode: 200, Request: req, Body: io.NopCloser(strings.NewReader(body))}, nil
	})}
	for _, origin := range []string{"https://one.example/registry.json", "https://two.example/registry.json"} {
		snapshot, err := read(context.Background(), client, origin)
		if err != nil {
			t.Fatal(err)
		}
		agent := snapshot.Agents[0]
		if snapshot.Source != origin || snapshot.ResolvedURL != origin || len(snapshot.SHA256) != 64 ||
			agent.PublisherVerification != "unverified" || agent.Version != "2.1.0" ||
			agent.Distribution.Binary["darwin-aarch64"].Command != "./tool" ||
			agent.Distribution.NPX.Package != "@fixture/agent@2.1.0" ||
			agent.Distribution.UVX.Env["MODE"] != "acp" {
			t.Fatalf("unexpected catalog metadata: %+v, %+v", snapshot, agent)
		}
	}
}

func TestCatalogRejectsInvalidSourceAndAmbiguousIdentifiers(t *testing.T) {
	for _, source := range []string{"http://example.test/registry.json", "https://user:pw@example.test/registry.json", "https://example.test/catalog#entry"} {
		if _, err := readURL(source); err == nil {
			t.Errorf("accepted invalid source %q", source)
		}
	}
	for _, body := range []string{
		`{"version":"2.0.0","agents":[]}`,
		`{"version":"1.0.0"}`,
		`{"version":"1.0.0","agents":[{"id":"entry","name":"A","version":"1.0.0"},{"id":"entry","name":"B","version":"2.0.0"}]}`,
	} {
		if _, err := decode("https://example.test", "https://example.test", []byte(body)); err == nil {
			t.Errorf("accepted invalid registry %s", body)
		}
	}
}

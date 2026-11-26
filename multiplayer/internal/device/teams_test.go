package device

import "testing"

func TestLooksSecret(t *testing.T) {
	for _, s := range []string{"token=abcdef123456", "ghp_abcdefghijklmnopqrstuvwxyz123456", "-----BEGIN RSA PRIVATE KEY-----"} {
		if !LooksSecret(s) {
			t.Errorf("missed %q", s)
		}
	}
	for _, s := range []string{"token=${GITHUB_TOKEN}", "Use the review skill", `"env": {"API_KEY": "${API_KEY}"}`} {
		if LooksSecret(s) {
			t.Errorf("false positive %q", s)
		}
	}
}

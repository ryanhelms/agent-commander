package provider

import "testing"

func TestACPDisconnectRecognizesRacingPromptFailure(t *testing.T) {
	for _, tc := range []struct {
		reason       string
		disconnected bool
	}{
		{"adapter disconnected", true},
		{`session/prompt: {"code":-32603,"message":"Internal error","data":{"error":"peer disconnected before response"}}`, true},
		{`session/prompt: {"code":-32603,"message":"Internal error","data":{"error":"provider quota exhausted"}}`, false},
		{"cancelled", false},
	} {
		if actual := acpDisconnected(tc.reason); actual != tc.disconnected {
			t.Errorf("disconnect classification for %q = %t, want %t", tc.reason, actual, tc.disconnected)
		}
	}
}

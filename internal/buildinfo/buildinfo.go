// Package buildinfo reports which Commander build is running.
package buildinfo

import (
	"runtime/debug"
	"strings"
)

// APIVersion is the major version of the local Commander API. A client and
// service with different values cannot work together. Raise it only for an
// incompatible change.
const APIVersion = 1

// Version is the release tag, set at build time with
// -ldflags "-X agentcommander/internal/buildinfo.Version=v0.2.0".
var Version = ""

// Current returns the release tag, or "dev" with the VCS revision for a
// local build.
func Current() string {
	if Version != "" {
		return Version
	}
	if info, ok := debug.ReadBuildInfo(); ok {
		for _, s := range info.Settings {
			if s.Key == "vcs.revision" && len(s.Value) >= 12 {
				return "dev-" + s.Value[:12]
			}
		}
	}
	return "dev"
}

// IsRelease reports whether v names a tagged release rather than a local
// build.
func IsRelease(v string) bool { return strings.HasPrefix(v, "v") }

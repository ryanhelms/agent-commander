//go:build !darwin && !linux

package hostmode

import "errors"

var errNoServiceManager = errors.New("host install supports launchd on macOS and systemd on Linux; run commander-relay host under your own supervisor")

func Install(string) error { return errNoServiceManager }

func Uninstall() error { return errNoServiceManager }

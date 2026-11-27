//go:build !darwin || !cgo

package actions

func desktopProcessHome() string              { return "" }
func desktopProcessMatches(launchRecord) bool { return false }

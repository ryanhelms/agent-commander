//go:build !darwin || !cgo

package devicekeys

import "errors"

func Keychain(account string) (Store, error) {
	return nil, errors.New("the OS device store requires the macOS build with Keychain support")
}

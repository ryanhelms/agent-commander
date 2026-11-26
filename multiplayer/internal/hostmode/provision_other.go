//go:build !linux

package hostmode

import "errors"

// Provision installs the relay as a Linux system service.
func Provision(string, Config, func(string)) error {
	return errors.New("provision installs a Linux system service; run it on the Linux server")
}

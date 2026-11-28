//go:build darwin && cgo

package devicekeys

import (
	"errors"
	"strings"
	"testing"
)

func TestKeychainErrorClassifiesAuthorizationFailures(t *testing.T) {
	for _, operation := range []string{"read", "write"} {
		// errAuthorizationInternal is returned when authorization could not be obtained.
		err := keychainError(operation, -60008)
		if !errors.Is(err, ErrKeychainAccess) {
			t.Errorf("%s authorization failure = %v, want ErrKeychainAccess", operation, err)
		}
		if !strings.Contains(err.Error(), operation+" Keychain item (OSStatus -60008)") {
			t.Errorf("%s authorization failure lost its diagnostic: %v", operation, err)
		}
	}

	if err := keychainError("read", -25308); !errors.Is(err, ErrKeychainAccess) {
		t.Errorf("errSecInteractionNotAllowed = %v, want ErrKeychainAccess", err)
	}
	if err := keychainError("read", -26275); errors.Is(err, ErrKeychainAccess) {
		t.Errorf("errSecDecode = %v, want ordinary Keychain error", err)
	}
}

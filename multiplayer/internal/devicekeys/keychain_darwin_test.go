//go:build darwin && cgo

package devicekeys

import (
	"errors"
	"fmt"
	"strings"
	"testing"
)

func TestKeychainErrorClassifiesAuthorizationFailures(t *testing.T) {
	for _, operation := range []string{"read", "write"} {
		for _, tt := range []struct {
			status int
			err    error
		}{
			{-60008, keychainError(operation, -60008)}, // errAuthorizationInternal
			{-25320, keychainError(operation, -25320)}, // errSecInDarkWake
		} {
			if !errors.Is(tt.err, ErrKeychainAccess) {
				t.Errorf("%s authorization failure = %v, want ErrKeychainAccess", operation, tt.err)
			}
			want := fmt.Sprintf("%s Keychain item (OSStatus %d)", operation, tt.status)
			if !strings.Contains(tt.err.Error(), want) {
				t.Errorf("%s authorization failure lost its diagnostic: %v", operation, tt.err)
			}
		}
	}

	if err := keychainError("read", -25308); !errors.Is(err, ErrKeychainAccess) {
		t.Errorf("errSecInteractionNotAllowed = %v, want ErrKeychainAccess", err)
	}
	if err := keychainError("read", -25300); errors.Is(err, ErrKeychainAccess) {
		t.Errorf("errSecItemNotFound = %v, want ordinary Keychain error", err)
	}
	if err := keychainError("read", -26275); errors.Is(err, ErrKeychainAccess) {
		t.Errorf("errSecDecode = %v, want ordinary Keychain error", err)
	}
}

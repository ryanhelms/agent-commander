package toolregistry

import "errors"

// These outcomes may be shared with callers. Other connector errors stay private.
var (
	ErrNotFound    = errors.New("scoped tool resource not found")
	ErrUnavailable = errors.New("scoped tool unavailable")
	ErrRateLimited = errors.New("scoped tool upstream rate limit reached")
)

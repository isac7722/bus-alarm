package server

import "errors"

// Only messages constructed from fixed diagnostics and setting names may use
// this type. Never include environment values, driver errors, or key contents.
type startupFailure string

func (e startupFailure) Error() string { return string(e) }

// CommandFailureMessage exposes actionable startup diagnostics while keeping
// arbitrary driver/transport errors (which can contain credentials) private.
func CommandFailureMessage(err error) string {
	var failure startupFailure
	if errors.As(err, &failure) {
		return string(failure)
	}
	return "Check configuration and required services"
}

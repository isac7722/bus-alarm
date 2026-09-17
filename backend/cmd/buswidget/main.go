package main

import (
	"fmt"
	"os"

	"buswidget/internal/server"
)

func main() {
	if err := server.Run(os.Args[1:]); err != nil {
		// Only explicitly safe startup diagnostics may be included in the message.
		server.NewLogger().Error("command_failed", "error_type", fmt.Sprintf("%T", err), "message", server.CommandFailureMessage(err))
		os.Exit(1)
	}
}

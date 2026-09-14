package main

import (
	"fmt"
	"os"

	"buswidget/internal/server"
)

func main() {
	if err := server.Run(os.Args[1:]); err != nil {
		// Driver and transport errors can contain credentials. Log their type only.
		server.NewLogger().Error("command_failed", "error_type", fmt.Sprintf("%T", err), "message", "Check configuration and required services")
		os.Exit(1)
	}
}

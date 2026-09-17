package server

import (
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

func TestCommandFailureDiagnosticsAndRedaction(t *testing.T) {
	secret := "private-password-value"
	for _, err := range []error{
		errors.New("postgresql://user:" + secret + "@localhost/db"),
		fmt.Errorf("transport failed for serviceKey=%s", secret),
	} {
		if message := CommandFailureMessage(err); message != "Check configuration and required services" {
			t.Fatal("raw error exposed", message)
		}
	}
	_, configErr := parseConfig(map[string]string{"MOCK_ARRIVALS": secret})
	apnsErr := validateAPNsConfig(Config{APNsKeyID: secret})
	_, keyErr := NewAPNsClient(Config{APNsKeyPath: filepath.Join(t.TempDir(), secret)})
	for _, tc := range []struct {
		err  error
		want string
	}{
		{configErr, "MOCK_ARRIVALS"},
		{apnsErr, "docker-compose.apns.yml"},
		{keyErr, "secret mount"},
		{fmt.Errorf("%s: %w", secret, configErr), "MOCK_ARRIVALS"},
	} {
		message := CommandFailureMessage(tc.err)
		if !strings.Contains(message, tc.want) || strings.Contains(message, secret) {
			t.Fatal("unsafe or missing startup diagnostic", message)
		}
	}
}

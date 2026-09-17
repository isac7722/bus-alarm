package server

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
)

// Read-only upstream diagnostic: no DB, no Redis, no APNs, no credential output.
func CheckRoutes(ctx context.Context, config Config) (err error) {
	transport := newTransport(config.HTTPTimeout)
	defer transport.CloseIdleConnections()
	c := &RouteCatalog{Config: config, HTTP: &http.Client{Transport: transport, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}}
	report := map[string]any{"check": "route_map", "station_number": "05267", "route_number": "9304", "success": false}
	defer func() {
		if err != nil {
			report["message"] = err.Error()
		}
		_ = json.NewEncoder(os.Stdout).Encode(report)
	}()
	search, err := c.Search(ctx, "9304")
	if err != nil {
		return err
	}
	report["providers"] = search.Providers
	var ref string
	for _, r := range search.Routes {
		if strings.HasPrefix(r.RouteRef, "gg:") && strings.HasPrefix(r.Name, "9304") {
			ref = r.RouteRef
			break
		}
	}
	if ref == "" {
		return fmt.Errorf("9304 route unavailable; check route service approvals and decoded keys")
	}
	detail, err := c.Detail(ctx, ref)
	if err != nil {
		return err
	}
	report["route_ref"] = ref
	var selected []BoardingSelection
	for _, s := range detail.Stops {
		if s.Station.DisplayNumber == "05267" && strings.HasSuffix(s.StationRef, ":104000069") && s.Selectable {
			selected = append(selected, s.BoardingSelection)
		}
	}
	if len(selected) == 0 {
		return fmt.Errorf("05267 boarding direction could not be verified")
	}
	for _, b := range selected {
		if _, err = c.BoardingLive(ctx, b); err != nil {
			return err
		}
	}
	report["verified_boardings"] = selected
	// Exercise a Seoul-owned route as well; a partial provider result is not success.
	seoul, err := c.Search(ctx, "370")
	if err != nil {
		return err
	}
	var sr string
	for _, r := range seoul.Routes {
		if strings.HasPrefix(r.RouteRef, "seoul:") && r.Name == "370" {
			sr = r.RouteRef
			break
		}
	}
	if sr == "" {
		return fmt.Errorf("Seoul route lookup unavailable")
	}
	sd, err := c.Detail(ctx, sr)
	if err != nil {
		return err
	}
	verified := false
	for _, s := range sd.Stops {
		if s.Selectable {
			_, err = c.BoardingLive(ctx, s.BoardingSelection)
			if err != nil {
				return err
			}
			verified = true
			break
		}
	}
	if !verified {
		return fmt.Errorf("Seoul route direction unavailable")
	}
	report["success"] = true
	return nil
}

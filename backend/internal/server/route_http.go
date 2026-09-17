package server

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"
)

func decodeRouteRequest(w http.ResponseWriter, r *http.Request, v any) error {
	d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16384))
	d.DisallowUnknownFields()
	if d.Decode(v) != nil || d.Decode(new(any)) != io.EOF {
		return invalid()
	}
	return nil
}
func (h *Handler) serveRoutes(w http.ResponseWriter, r *http.Request) int {
	ctx, cancel := context.WithTimeout(r.Context(), 25*time.Second)
	defer cancel()
	r = r.WithContext(ctx)
	w.Header().Set("Cache-Control", "no-store")
	path := strings.TrimPrefix(r.URL.Path, "/api/v2")
	if path == "/capabilities" && r.Method == "GET" {
		writeJSON(w, 200, map[string]any{"route_map": h.Config.RouteMapEnabled && h.Catalog != nil, "providers": []ProviderStatus{{Provider: "seoul", Available: h.Config.APIKey != ""}, {Provider: "gg", Available: h.Config.GyeonggiAPIKey != ""}}})
		return 200
	}
	if h.Catalog == nil {
		return h.writeError(w, appError("ROUTE_MAP_UNAVAILABLE", "노선 선택 서비스를 준비 중입니다.", 503))
	}
	if path == "/live-activities" {
		return h.serveLive(w, r)
	}
	method := "GET"
	if path == "/arrivals" || path == "/selections/validate" {
		method = "POST"
	}
	if r.Method != method {
		w.Header().Set("Allow", method)
		writeJSON(w, 405, map[string]string{"detail": "Method Not Allowed"})
		return 405
	}
	var result any
	var err error
	switch {
	case path == "/stations/nearby":
		var bounds StationBounds
		bounds, err = stationBounds(r)
		if err == nil {
			result, err = h.Catalog.StationsInBounds(r.Context(), bounds)
		}
	case path == "/routes/search":
		result, err = h.Catalog.Search(r.Context(), lastQuery(r, "q"))
	case strings.HasPrefix(path, "/routes/"):
		tail := strings.TrimPrefix(path, "/routes/")
		if ref, ok := strings.CutSuffix(tail, "/geometry"); ok {
			result, err = h.Catalog.Geometry(r.Context(), ref)
		} else {
			result, err = h.Catalog.Detail(r.Context(), tail)
		}
	case strings.HasPrefix(path, "/stations/") && strings.HasSuffix(path, "/boarding-options"):
		ref := strings.TrimSuffix(strings.TrimPrefix(path, "/stations/"), "/boarding-options")
		result, err = h.Catalog.Options(r.Context(), ref, lastQuery(r, "route_ref"))
	case path == "/stations/resolve":
		var station *Station
		station, err = h.Service.requireStation(r.Context(), lastQuery(r, "id"))
		if err == nil {
			p := "seoul"
			if strings.HasPrefix(station.StationID, "gg:") {
				p = "gg"
			}
			result = MapStation{p + ":" + station.NodeID, station.Name, number(station.StationID), &station.Latitude, &station.Longitude}
			if p == "gg" {
				result = MapStation{p + ":" + station.NodeID, station.Name, station.MobileNo, &station.Latitude, &station.Longitude}
			}
		}
	case path == "/arrivals" || path == "/selections/validate":
		var req SelectionRequest
		err = decodeRouteRequest(w, r, &req)
		if err == nil {
			if path == "/arrivals" {
				result, err = h.Catalog.Arrivals(r.Context(), req)
			} else {
				result, err = h.Catalog.Validate(r.Context(), req)
			}
		}
	default:
		writeJSON(w, 404, map[string]string{"detail": "Not Found"})
		return 404
	}
	if err != nil {
		return h.writeError(w, err)
	}
	writeJSON(w, 200, result)
	return 200
}

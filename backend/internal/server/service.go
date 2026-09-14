package server

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"strings"
)

type Service struct {
	Repository Repository
	Cache      Cache
	Client     ArrivalClient
	Log        *slog.Logger
}

func (s *Service) requireStation(ctx context.Context, id string) (*Station, error) {
	station, err := s.Repository.Get(ctx, id)
	if err != nil {
		return nil, err
	}
	if station == nil {
		return nil, appError("STATION_NOT_FOUND", "정류소를 찾을 수 없습니다.", 404)
	}
	return station, nil
}
func (s *Service) Search(ctx context.Context, q string) (any, error) {
	q = strings.TrimSpace(q)
	if q == "" {
		return nil, appError("INVALID_REQUEST", "검색어를 입력해 주세요.", 400)
	}
	rows, err := s.Repository.Search(ctx, q)
	if err != nil {
		return nil, err
	}
	stations := []StationSummary{}
	for _, row := range rows {
		stations = append(stations, summary(row))
	}
	return struct {
		Stations []StationSummary `json:"stations"`
	}{stations}, nil
}
func (s *Service) Detail(ctx context.Context, id string) (any, error) {
	station, err := s.requireStation(ctx, id)
	if err != nil {
		return nil, err
	}
	routes, err := s.Repository.Routes(ctx, id)
	if err != nil {
		return nil, err
	}
	return struct {
		Station StationSummary `json:"station"`
		Routes  []Route        `json:"routes"`
	}{summary(*station), routes}, nil
}
func (s *Service) Arrivals(ctx context.Context, id, routeIDs string) (ArrivalsResponse, error) {
	empty := ArrivalsResponse{}
	station, err := s.requireStation(ctx, id)
	if err != nil {
		return empty, err
	}
	requested := []string{}
	seen := map[string]bool{}
	for _, value := range strings.Split(routeIDs, ",") {
		v := strings.TrimSpace(value)
		if v != "" && !seen[v] {
			requested = append(requested, v)
			seen[v] = true
		}
	}
	if len(requested) > 4 {
		return empty, appError("INVALID_REQUEST", "노선은 최대 4개까지 요청할 수 있습니다.", 400)
	}
	if len(requested) > 0 {
		routes, err := s.Repository.Routes(ctx, id)
		if err != nil {
			return empty, err
		}
		ids := map[string]bool{}
		for _, r := range routes {
			ids[r.RouteID] = true
		}
		for _, r := range requested {
			if !ids[r] {
				return empty, appError("ROUTE_NOT_FOUND", "정류소에서 요청한 노선을 찾을 수 없습니다.", 404)
			}
		}
	}
	key := "station:" + id + ":arrivals:" + s.Client.Namespace()
	cached, err := s.Cache.Get(ctx, key)
	if err != nil {
		return empty, err
	}
	var response ArrivalsResponse
	if cached != nil {
		s.Log.Info("arrival_cache_hit", "station_id", id, "action", "get_arrivals")
		if err := decodeCached(cached, &response); err != nil {
			return empty, err
		}
	} else {
		s.Log.Info("arrival_cache_miss", "station_id", id, "action", "get_arrivals")
		routes, err := s.Repository.Routes(ctx, id)
		if err != nil {
			return empty, err
		}
		response, err = s.Client.Fetch(ctx, id, routes)
		if err != nil {
			return empty, err
		}
		response.Station = ArrivalStation{station.StationID, station.Name}
		b, err := json.Marshal(response)
		if err != nil {
			return empty, err
		}
		if err := s.Cache.Set(ctx, key, b); err != nil {
			return empty, err
		}
	}
	if len(requested) == 0 {
		return response, nil
	}
	byRoute := map[string]RouteArrival{}
	for _, a := range response.Arrivals {
		byRoute[a.RouteID] = a
	}
	filtered := []RouteArrival{}
	missing := []string{}
	for _, id := range requested {
		if a, ok := byRoute[id]; ok {
			filtered = append(filtered, a)
		} else {
			missing = append(missing, id)
		}
	}
	if len(missing) > 0 {
		routes, err := s.Repository.Routes(ctx, id)
		if err != nil {
			return empty, err
		}
		names := map[string]string{}
		for _, r := range routes {
			names[r.RouteID] = r.Name
		}
		for _, id := range missing {
			filtered = append(filtered, RouteArrival{id, names[id], []Prediction{}})
		}
	}
	response.Arrivals = filtered
	return response, nil
}
func decodeCached(b []byte, out *ArrivalsResponse) error {
	if err := json.Unmarshal(b, out); err != nil {
		return err
	}
	var raw map[string]json.RawMessage
	_ = json.Unmarshal(b, &raw)
	for _, key := range []string{"station", "updated_at", "fetched_at", "arrivals"} {
		if len(raw[key]) == 0 || string(raw[key]) == "null" {
			return fmt.Errorf("invalid cached arrivals")
		}
	}
	var station map[string]json.RawMessage
	_ = json.Unmarshal(raw["station"], &station)
	for _, key := range []string{"station_id", "name"} {
		if len(station[key]) == 0 || string(station[key]) == "null" {
			return fmt.Errorf("invalid cached station")
		}
	}
	if out.UpdatedAt.IsZero() || out.FetchedAt.IsZero() || out.Arrivals == nil {
		return fmt.Errorf("invalid cached arrivals")
	}
	var arrivals []map[string]json.RawMessage
	if err := json.Unmarshal(raw["arrivals"], &arrivals); err != nil {
		return err
	}
	for _, a := range arrivals {
		for _, key := range []string{"route_id", "route_name", "predictions"} {
			if len(a[key]) == 0 || string(a[key]) == "null" {
				return fmt.Errorf("invalid cached route")
			}
		}
		var predictions []map[string]json.RawMessage
		if err := json.Unmarshal(a["predictions"], &predictions); err != nil {
			return err
		}
		for _, p := range predictions {
			if len(p["arrival_at"]) == 0 {
				return fmt.Errorf("invalid cached arrival time")
			}
		}
	}
	for _, a := range out.Arrivals {
		if a.Predictions == nil || len(a.Predictions) > 2 {
			return fmt.Errorf("invalid cached predictions")
		}
		for _, p := range a.Predictions {
			if p.Order < 1 || p.Order > 2 || p.RemainingSeconds != nil && *p.RemainingSeconds < 0 || p.RemainingStops != nil && *p.RemainingStops < 0 {
				return fmt.Errorf("invalid cached prediction")
			}
			switch p.VehicleStatus {
			case "RUNNING", "WAITING", "NOT_AVAILABLE", "UNKNOWN":
			default:
				return fmt.Errorf("invalid cached vehicle status")
			}
		}
	}
	return nil
}

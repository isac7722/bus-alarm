package server

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// Timestamp preserves Pydantic's six-digit fractional seconds and UTC spelling.
type Timestamp struct{ time.Time }

func (t Timestamp) MarshalJSON() ([]byte, error) {
	layout := "2006-01-02T15:04:05"
	if t.Nanosecond()/1000 != 0 {
		layout += ".000000"
	}
	return json.Marshal(t.Format(layout + "Z07:00"))
}
func (t *Timestamp) UnmarshalJSON(b []byte) error { return json.Unmarshal(b, &t.Time) }
func stamp(t time.Time) Timestamp                 { return Timestamp{t.Truncate(time.Microsecond)} }

type Station struct {
	StationID string  `json:"station_id"`
	NodeID    string  `json:"-"`
	Name      string  `json:"name"`
	Longitude float64 `json:"longitude"`
	Latitude  float64 `json:"latitude"`
	MobileNo  string  `json:"-"`
}
type StationSummary struct {
	StationID string  `json:"station_id"`
	ARSID     string  `json:"ars_id"`
	Name      string  `json:"name"`
	Direction *string `json:"direction"`
	Latitude  float64 `json:"latitude"`
	Longitude float64 `json:"longitude"`
}

func summary(s Station) StationSummary {
	id := s.StationID
	if strings.HasPrefix(id, "gg:") {
		id = s.MobileNo
	}
	runes := []rune(id)
	if len(runes) == 5 {
		id = string(runes[:2]) + "-" + string(runes[2:])
	}
	return StationSummary{s.StationID, id, s.Name, nil, s.Latitude, s.Longitude}
}

type Route struct {
	RouteID string `json:"route_id"`
	Name    string `json:"route_name"`
}
type Prediction struct {
	Order            int        `json:"order"`
	ArrivalAt        *Timestamp `json:"arrival_at"`
	RemainingSeconds *int       `json:"remaining_seconds"`
	RemainingStops   *int       `json:"remaining_stops"`
	VehicleStatus    string     `json:"vehicle_status"`
}
type RouteArrival struct {
	RouteID     string       `json:"route_id"`
	RouteName   string       `json:"route_name"`
	Predictions []Prediction `json:"predictions"`
}
type ArrivalStation struct {
	StationID string `json:"station_id"`
	Name      string `json:"name"`
}
type ArrivalsResponse struct {
	RouteUpdatedAt map[string]Timestamp `json:"route_updated_at,omitempty"`
	FailedRouteIDs []string             `json:"failed_route_ids,omitempty"`
	Station        ArrivalStation       `json:"station"`
	UpdatedAt      Timestamp            `json:"updated_at"`
	FetchedAt      Timestamp            `json:"fetched_at"`
	Arrivals       []RouteArrival       `json:"arrivals"`
}
type AppError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	Status  int    `json:"-"`
}

func (e *AppError) Error() string                     { return fmt.Sprintf("%s: %s", e.Code, e.Message) }
func appError(code, message string, status int) error { return &AppError{code, message, status} }
func invalid() error {
	return appError("INVALID_REQUEST", "요청 형식이 올바르지 않습니다.", 400)
}
func cacheError() error {
	return appError("CACHE_ERROR", "캐시 서버를 일시적으로 사용할 수 없습니다.", 503)
}
func upstreamError(message string) error { return appError("SEOUL_BUS_API_ERROR", message, 502) }

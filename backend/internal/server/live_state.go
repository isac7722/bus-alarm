package server

import (
	"bytes"
	"context"
	"encoding/xml"
	"time"

	"golang.org/x/net/html/charset"
)

// Unix seconds are Doubles in Swift, not Foundation's default Date epoch.
type LiveRouteContent struct {
	RouteID string      `json:"routeId"`
	Content LiveContent `json:"content"`
}

type LiveContent struct {
	Revision       int64              `json:"revision,omitempty"`
	Routes         []LiveRouteContent `json:"routes,omitempty"`
	Status         string             `json:"status"`
	ArrivalAt      *float64           `json:"arrivalAt"`
	RemainingStops *int               `json:"remainingStops"`
	UpdatedAt      float64            `json:"updatedAt"`
}

type LiveBus struct {
	Prediction Prediction
	VehicleID  string
}
type LiveSnapshot struct {
	UpdatedAt time.Time
	Buses     map[string][]LiveBus
}

// Vehicle IDs stay inside the tracker; the existing arrivals API/cache is unchanged.
func (c *SeoulClient) FetchLive(ctx context.Context, id string, _ []Route) (LiveSnapshot, error) {
	body, err := c.fetchBody(ctx, id)
	if err != nil {
		return LiveSnapshot{}, err
	}
	return parseLiveSnapshot(body, c.Now().UTC())
}
func parseLiveSnapshot(body []byte, now time.Time) (LiveSnapshot, error) {
	response, err := ParseArrivals(body, now)
	if err != nil {
		return LiveSnapshot{}, err
	}
	decoder := xml.NewDecoder(bytes.NewReader(body))
	decoder.CharsetReader = charset.NewReaderLabel
	var root xmlNode
	if err := decoder.Decode(&root); err != nil {
		return LiveSnapshot{}, err
	}
	items := root.descendants("msgBody", "itemList")
	if len(items) == 0 {
		items = root.descendants("itemList")
	}
	out := LiveSnapshot{UpdatedAt: response.UpdatedAt.Time, Buses: map[string][]LiveBus{}}
	for _, item := range items {
		for i, suffix := range []string{"1", "2"} {
			vehicle := item.child("vehId" + suffix)
			if vehicle == "0" {
				vehicle = ""
			}
			out.Buses[item.child("busRouteId")] = append(out.Buses[item.child("busRouteId")], LiveBus{parsePrediction(item, i+1, out.UpdatedAt), vehicle})
		}
	}
	return out, nil
}
func (m *MockClient) FetchLive(_ context.Context, _ string, routes []Route) (LiveSnapshot, error) {
	// A stable vehicle per five-minute cycle lets a mock wait actually finish.
	now := m.Now().UTC()
	cycle := now.Unix() / 300
	seconds := int(299 - now.Unix()%300)
	at := stamp(now.Add(time.Duration(seconds) * time.Second))
	out := LiveSnapshot{UpdatedAt: now, Buses: map[string][]LiveBus{}}
	for _, route := range routes {
		stops := seconds / 60
		out.Buses[route.RouteID] = []LiveBus{{Prediction{1, &at, &seconds, &stops, "RUNNING"}, time.Unix(cycle*300, 0).Format(time.RFC3339)}}
	}
	return out, nil
}

type LiveSession struct {
	Routes        []LiveSession      `json:"routes,omitempty"`
	Boarding      *BoardingSelection `json:"boarding,omitempty"`
	StationID     string             `json:"station_id"`
	RouteID       string             `json:"route_id"`
	PushToken     string             `json:"push_token"`
	Environment   string             `json:"environment"`
	ExpiresAt     int64              `json:"expires_at"`
	NextRefreshAt int64              `json:"next_refresh_at"`
	PushRetry     int                `json:"push_retry"`
	NextPushAt    int64              `json:"next_push_at"`
	VehicleID     string             `json:"vehicle_id"`
	LastSeenAt    int64              `json:"last_seen_at"`
	LastArrivalAt int64              `json:"last_arrival_at"`
	Content       LiveContent        `json:"content"`
	Ended         bool               `json:"ended"`
}

func (s *LiveSession) advance(snapshot LiveSnapshot, now time.Time) {
	if s.Ended {
		return
	}
	if now.Unix() >= s.ExpiresAt {
		s.Content = LiveContent{Status: "expired", UpdatedAt: float64(now.Unix())}
		s.Ended = true
		return
	}
	// An old prediction must never turn into an assertion that the bus arrived.
	if snapshot.UpdatedAt.IsZero() || now.Sub(snapshot.UpdatedAt) > 90*time.Second || snapshot.UpdatedAt.After(now.Add(30*time.Second)) {
		// Transport failure or an old source snapshot must not erase the last ETA.
		if s.Content.Status == "" {
			s.Content = LiveContent{Status: "unavailable"}
		}
		return
	}
	if s.LastSeenAt > 0 && snapshot.UpdatedAt.Unix() < s.LastSeenAt {
		return
	}
	var selected *LiveBus
	buses := snapshot.Buses[s.RouteID]
	for i := range buses {
		bus := &buses[i]
		if bus.Prediction.VehicleStatus != "RUNNING" || bus.Prediction.ArrivalAt == nil {
			continue
		}
		if s.VehicleID != "" && bus.VehicleID != s.VehicleID {
			continue
		}
		if selected == nil || bus.Prediction.Order < selected.Prediction.Order {
			selected = bus
		}
	}
	if selected == nil {
		followingBus := false
		for _, bus := range buses {
			if bus.VehicleID != "" && bus.VehicleID != s.VehicleID && bus.Prediction.VehicleStatus == "RUNNING" {
				followingBus = true
			}
		}
		// A tracked vehicle disappearing near its last ETA means an estimated passage,
		// not confirmed boarding. Do not silently switch to the following bus.
		if followingBus && snapshot.UpdatedAt.Unix() > s.LastSeenAt && s.VehicleID != "" && s.LastSeenAt > 0 && now.Unix()-s.LastSeenAt <= 120 && s.LastArrivalAt <= now.Unix()+30 && s.LastArrivalAt >= now.Unix()-120 {
			s.Content = LiveContent{Status: "passed", UpdatedAt: float64(snapshot.UpdatedAt.Unix())}
			s.Ended = true
		} else {
			s.Content = LiveContent{Status: "unavailable", UpdatedAt: float64(snapshot.UpdatedAt.Unix())}
		}
		return
	}
	p := selected.Prediction
	if p.ArrivalAt.Before(snapshot.UpdatedAt.Add(-30 * time.Second)) {
		s.Content = LiveContent{Status: "unavailable", UpdatedAt: float64(snapshot.UpdatedAt.Unix())}
		return
	}
	s.VehicleID = selected.VehicleID
	s.LastSeenAt = snapshot.UpdatedAt.Unix()
	s.LastArrivalAt = p.ArrivalAt.Unix()
	at := float64(p.ArrivalAt.Unix())
	s.Content = LiveContent{Status: "waiting", ArrivalAt: &at, RemainingStops: p.RemainingStops, UpdatedAt: float64(snapshot.UpdatedAt.Unix())}
	if p.RemainingSeconds != nil && *p.RemainingSeconds == 0 {
		s.Content.Status = "arrived"
		s.Ended = true
	}
}

package server

import (
	"context"
	"sort"
	"strings"
	"sync"
)

// RegionalClient keeps existing Seoul ARS IDs while addressing GBIS-only stops
// by provider and node ID. A shared mobile number alone never joins two stops.
type RegionalClient struct {
	Seoul      *SeoulClient
	Gyeonggi   *GyeonggiClient
	Repository Repository
}

func (c *RegionalClient) Namespace() string { return "live-gbis-v1" }

func (c *RegionalClient) stationNode(ctx context.Context, id string) (string, bool, error) {
	if node, ok := strings.CutPrefix(id, "gg:"); ok {
		if !gbisNodeValid(node) {
			return "", false, invalid()
		}
		return node, false, nil
	}
	station, err := c.Repository.Get(ctx, id)
	if err != nil {
		return "", false, err
	}
	if station == nil {
		return "", false, appError("STATION_NOT_FOUND", "정류소를 찾을 수 없습니다.", 404)
	}
	if !gbisNodeValid(station.NodeID) {
		return "", false, gbisError()
	}
	return station.NodeID, true, nil
}

func (c *RegionalClient) SearchStations(ctx context.Context, keyword string) ([]Station, error) {
	stations, err := c.Gyeonggi.SearchStations(ctx, keyword)
	if err != nil {
		return nil, err
	}
	for i, station := range stations {
		if station.MobileNo == "" {
			continue
		}
		existing, err := c.Repository.Get(ctx, station.MobileNo)
		if err != nil {
			return nil, err
		}
		if existing != nil && existing.NodeID == station.NodeID {
			stations[i] = *existing
		}
	}
	return stations, nil
}

// Both providers must succeed: silently replacing a failed source with a
// partial catalog would make missing buses indistinguishable from no service.
func (c *RegionalClient) FetchRoutes(ctx context.Context, id string) ([]Route, error) {
	node, seoul, err := c.stationNode(ctx, id)
	if err != nil {
		return nil, err
	}
	var local, regional []Route
	var localErr, regionalErr error
	var wg sync.WaitGroup
	wg.Go(func() { regional, regionalErr = c.Gyeonggi.FetchRoutes(ctx, node) })
	if seoul {
		wg.Go(func() { local, localErr = c.Seoul.FetchRoutes(ctx, id) })
	}
	wg.Wait()
	if localErr != nil {
		return nil, localErr
	}
	if regionalErr != nil {
		return nil, regionalErr
	}
	byID := map[string]Route{}
	for _, route := range regional {
		byID[route.RouteID] = route
	}
	for _, route := range local {
		byID[route.RouteID] = route
	}
	out := make([]Route, 0, len(byID))
	for _, route := range byID {
		out = append(out, route)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Name == out[j].Name {
			return out[i].RouteID < out[j].RouteID
		}
		return out[i].Name < out[j].Name
	})
	return out, nil
}

func (c *RegionalClient) FetchLive(ctx context.Context, id string, routes []Route) (LiveSnapshot, error) {
	node, seoul, err := c.stationNode(ctx, id)
	if err != nil {
		return LiveSnapshot{}, err
	}
	var local, regional LiveSnapshot
	var localErr, regionalErr error
	var wg sync.WaitGroup
	wg.Go(func() {
		// Routes determine a stable source, even when GBIS has no active bus.
		// This prevents switching tracked vehicles between providers.
		ggRoutes, err := c.Gyeonggi.FetchRoutes(ctx, node)
		if err != nil {
			regionalErr = err
			return
		}
		regional, regionalErr = c.Gyeonggi.FetchLive(ctx, node, ggRoutes)
	})
	if seoul {
		wg.Go(func() { local, localErr = c.Seoul.FetchLive(ctx, id, routes) })
	}
	wg.Wait()
	if localErr != nil {
		return LiveSnapshot{}, localErr
	}
	if regionalErr != nil {
		return LiveSnapshot{}, regionalErr
	}
	if !seoul {
		return regional, nil
	}
	for id, buses := range regional.Buses {
		local.Buses[id] = buses
	}
	if regional.UpdatedAt.Before(local.UpdatedAt) {
		local.UpdatedAt = regional.UpdatedAt
	}
	return local, nil
}

func (c *RegionalClient) Fetch(ctx context.Context, id string, routes []Route) (ArrivalsResponse, error) {
	snapshot, err := c.FetchLive(ctx, id, routes)
	if err != nil {
		return ArrivalsResponse{}, err
	}
	out := ArrivalsResponse{UpdatedAt: stamp(snapshot.UpdatedAt), FetchedAt: stamp(c.Gyeonggi.Now().UTC()), Arrivals: []RouteArrival{}}
	for _, route := range routes {
		arrival := RouteArrival{route.RouteID, route.Name, []Prediction{}}
		for _, bus := range snapshot.Buses[route.RouteID] {
			arrival.Predictions = append(arrival.Predictions, bus.Prediction)
		}
		out.Arrivals = append(out.Arrivals, arrival)
	}
	return out, nil
}

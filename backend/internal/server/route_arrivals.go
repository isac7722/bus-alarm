package server

import (
	"context"
	"net/url"
	"strconv"
	"sync"
	"time"
)

// Selection is validated before callers enter this function. V2 never falls back
// to a station-wide snapshot that could belong to the opposite direction.
func (c *RouteCatalog) BoardingLive(ctx context.Context, b BoardingSelection) (LiveSnapshot, error) {
	out := LiveSnapshot{Buses: map[string][]LiveBus{b.RouteRef: {}}}
	p, id, e := splitRef(b.RouteRef)
	if e != nil {
		return out, e
	}
	_, node, e := splitRef(b.StationRef)
	if e != nil {
		return out, e
	}
	path := "/arrive/getArrInfoByRouteAll"
	q := url.Values{"busRouteId": {id}}
	itemName := "itemList"
	if p == "gg" {
		path = "/busarrivalservice/v2/getBusArrivalItemv2"
		q = url.Values{"stationId": {node}, "routeId": {id}, "staOrder": {strconv.Itoa(b.Sequence)}}
		itemName = "busArrivalItem"
	}
	root, e := c.request(ctx, p, path, q, 5*time.Second)
	if e != nil {
		return out, e
	}
	now := time.Now().UTC()
	if !root.FetchedAt.IsZero() {
		now = root.FetchedAt
	}
	out.UpdatedAt = now
	if p == "gg" {
		if t := firstText(root, []string{"msgHeader", "queryTime"}); t != "" {
			parsed := parseMktime(t)
			if parsed == nil {
				return out, routeError()
			}
			out.UpdatedAt = *parsed
		}
	}
	matched := false
	for _, n := range root.descendants("msgBody", itemName) {
		route, station, sequence := n.child("busRouteId"), n.child("stId"), n.child("staOrd")
		if p == "gg" {
			route, station, sequence = n.child("routeId"), n.child("stationId"), n.child("staOrder")
		}
		seq, err := strconv.Atoi(sequence)
		if err != nil {
			return out, routeError()
		}
		if route != id || station != node || seq != b.Sequence {
			if p == "gg" {
				return out, routeChanged()
			}
			continue
		}
		if matched {
			return out, routeError()
		}
		matched = true
		if p == "seoul" {
			if t := parseMktime(n.child("mkTm")); t != nil {
				out.UpdatedAt = *t
			} else {
				return out, routeError()
			}
		}
		for order := 1; order <= 2; order++ {
			var bus LiveBus
			if p == "gg" {
				bus = parseGBISPrediction(n, order, out.UpdatedAt)
			} else {
				bus = LiveBus{parsePrediction(n, order, out.UpdatedAt), n.child("vehId" + strconv.Itoa(order))}
				if bus.VehicleID == "0" {
					bus.VehicleID = ""
				} else if bus.VehicleID != "" {
					bus.VehicleID = "seoul:" + bus.VehicleID
				}
			}
			if order == 1 || bus.Prediction.VehicleStatus == "RUNNING" || bus.Prediction.VehicleStatus == "WAITING" {
				out.Buses[b.RouteRef] = append(out.Buses[b.RouteRef], bus)
			}
		}
	}
	if !matched && p == "seoul" {
		return out, routeChanged()
	}
	return out, nil
}
func (c *RouteCatalog) Arrivals(ctx context.Context, r SelectionRequest) (ArrivalsResponse, error) {
	valid, e := c.Validate(ctx, r)
	if e != nil {
		return ArrivalsResponse{}, e
	}
	out := ArrivalsResponse{Station: ArrivalStation{r.StationRef, valid.Station.Name}, FetchedAt: stamp(time.Now().UTC()), Arrivals: []RouteArrival{}}
	snapshots := make([]LiveSnapshot, len(valid.Selections))
	errors := make([]error, len(valid.Selections))
	var workers sync.WaitGroup
	for i, b := range valid.Selections {
		workers.Add(1)
		go func() { defer workers.Done(); snapshots[i], errors[i] = c.BoardingLive(ctx, b) }()
	}
	workers.Wait()
	out.RouteUpdatedAt = map[string]Timestamp{}
	for i, b := range valid.Selections {
		if errors[i] != nil {
			out.FailedRouteIDs = append(out.FailedRouteIDs, b.RouteRef)
			continue
		}
		s := snapshots[i]
		if out.UpdatedAt.IsZero() || s.UpdatedAt.Before(out.UpdatedAt.Time) {
			out.UpdatedAt = stamp(s.UpdatedAt)
		}
		out.RouteUpdatedAt[b.RouteRef] = stamp(s.UpdatedAt)
		a := RouteArrival{b.RouteRef, b.RouteName, []Prediction{}}
		for _, bus := range s.Buses[b.RouteRef] {
			a.Predictions = append(a.Predictions, bus.Prediction)
		}
		out.Arrivals = append(out.Arrivals, a)
	}
	if len(out.Arrivals) == 0 && len(errors) > 0 {
		return out, errors[0]
	}

	return out, nil
}

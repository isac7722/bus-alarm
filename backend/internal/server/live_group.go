package server

import (
	"context"
	"net/http"
	"strings"
	"time"
)

func validLiveRouteID(id string) bool {
	return id != "" && len(id) <= 32 && !strings.ContainsAny(id, ", \t\n")
}

func validLiveTargets(targets []liveTarget) bool {
	if len(targets) < 1 || len(targets) > 4 {
		return false
	}
	seen := map[string]bool{}
	for _, target := range targets {
		if !validLiveRouteID(target.RouteID) || seen[target.RouteID] {
			return false
		}
		seen[target.RouteID] = true
	}
	return true
}

func (h *Handler) serveLiveGroup(w http.ResponseWriter, r *http.Request, key string, registration liveRegistration) int {
	if registration.RouteID != "" || registration.Boarding != nil || !validLiveTargets(registration.Routes) {
		return h.writeError(w, invalid())
	}
	if r.URL.Path == "/api/v2/live-activities" {
		if h.Catalog == nil {
			return h.writeError(w, invalid())
		}
		selections := make([]BoardingSelection, len(registration.Routes))
		for i, target := range registration.Routes {
			if target.Boarding == nil || target.Boarding.RouteRef != target.RouteID {
				return h.writeError(w, invalid())
			}
			selections[i] = *target.Boarding
		}
		validated, err := h.Catalog.Validate(r.Context(), SelectionRequest{registration.StationID, selections})
		if err != nil {
			return h.writeError(w, err)
		}
		for i := range registration.Routes {
			registration.Routes[i].Boarding = &validated.Selections[i]
		}
	} else {
		if !stationIDValid(registration.StationID) {
			return h.writeError(w, invalid())
		}
		if _, err := h.Service.requireStation(r.Context(), registration.StationID); err != nil {
			return h.writeError(w, err)
		}
		routes, err := h.Service.StationRoutes(r.Context(), registration.StationID)
		if err != nil {
			return h.writeError(w, err)
		}
		for _, target := range registration.Routes {
			if target.Boarding != nil {
				return h.writeError(w, invalid())
			}
			found := false
			for _, route := range routes {
				if route.RouteID == target.RouteID {
					found = true
				}
			}
			if !found {
				return h.writeError(w, appError("ROUTE_NOT_FOUND", "정류소에서 요청한 노선을 찾을 수 없습니다.", 404))
			}
		}
	}
	initial := LiveSession{StationID: registration.StationID, Environment: registration.Environment}
	exists, err := h.Live.Redis.Exists(r.Context(), key).Result()
	if err != nil {
		return h.writeError(w, cacheError())
	}
	if exists == 0 {
		now := time.Now()
		initial.ExpiresAt = now.Add(liveLifetime).Unix()
		snapshots := map[string]LiveSnapshot{}
		for _, target := range registration.Routes {
			child := LiveSession{StationID: registration.StationID, RouteID: target.RouteID, Boarding: target.Boarding, ExpiresAt: initial.ExpiresAt}
			child.advance(h.Live.snapshot(r.Context(), child, snapshots), now)
			initial.Routes = append(initial.Routes, child)
		}
		initial.aggregate(time.Now())
		if initial.Content.ArrivalAt == nil || initial.Ended {
			return h.writeError(w, appError("LIVE_NO_PREDICTION", "선택한 노선에 도착 정보가 없습니다. 잠시 후 다시 시도해 주세요.", 409))
		}
	}
	var session LiveSession
	err = h.Live.mutate(r.Context(), key, func(current *LiveSession) error {
		if current.Ended || current.ExpiresAt != 0 && current.ExpiresAt <= time.Now().Unix() {
			return appError("LIVE_ACTIVITY_ENDED", "종료된 대기입니다. 새로 시작해 주세요.", 409)
		}
		if current.ExpiresAt == 0 {
			if initial.ExpiresAt == 0 {
				return invalid()
			}
			*current = initial
		} else {
			if current.StationID != registration.StationID || current.Environment != registration.Environment || len(current.Routes) != len(registration.Routes) {
				return invalid()
			}
			for i, target := range registration.Routes {
				if current.Routes[i].RouteID != target.RouteID || !sameBoarding(current.Routes[i].Boarding, target.Boarding) {
					return invalid()
				}
			}
		}
		current.PushToken = strings.ToLower(registration.PushToken)
		return nil
	}, &session)
	if err != nil {
		return h.writeError(w, err)
	}
	writeJSON(w, 200, map[string]any{"expires_at": session.ExpiresAt, "content": session.Content})
	return 200
}

// Reuse a snapshot within a worker pass, including across grouped and legacy waits.
func (l *LiveActivities) snapshot(ctx context.Context, session LiveSession, snapshots map[string]LiveSnapshot) LiveSnapshot {
	key := session.StationID
	if session.Boarding != nil {
		key = session.Boarding.BoardingID + ":" + session.Boarding.RouteRevision
	}
	if snapshot, ok := snapshots[key]; ok {
		return snapshot
	}
	var snapshot LiveSnapshot
	if time.Now().Unix() < session.ExpiresAt {
		fetchCtx, cancel := context.WithTimeout(ctx, 4*time.Second)
		defer cancel()
		if session.Boarding != nil {
			if l.Catalog != nil {
				valid, err := l.Catalog.Validate(fetchCtx, SelectionRequest{session.StationID, []BoardingSelection{*session.Boarding}})
				if err == nil {
					snapshot, _ = l.Catalog.BoardingLive(fetchCtx, valid.Selections[0])
				}
			}
		} else {
			routes, err := l.Service.StationRoutes(fetchCtx, session.StationID)
			if err == nil {
				snapshot, _ = l.Source.FetchLive(fetchCtx, session.StationID, routes)
			}
		}
	}
	snapshots[key] = snapshot
	return snapshot
}

// Individual vehicles finish independently; the activity ends only after all do.
func (s *LiveSession) aggregate(now time.Time) {
	content := LiveContent{Status: "unavailable", UpdatedAt: float64(now.Unix())}
	allEnded := true
	for _, child := range s.Routes {
		content.Routes = append(content.Routes, LiveRouteContent{child.RouteID, child.Content})
		allEnded = allEnded && child.Ended
		c := child.Content
		if !child.Ended && c.Status == "waiting" && c.ArrivalAt != nil && *c.ArrivalAt > float64(now.Unix()) && float64(now.Unix())-c.UpdatedAt <= 90 {
			// The system stale-date must not extend any displayed prediction's freshness.
			content.UpdatedAt = min(content.UpdatedAt, c.UpdatedAt)
			if content.ArrivalAt == nil || *c.ArrivalAt < *content.ArrivalAt {
				content.Status, content.ArrivalAt, content.RemainingStops = "waiting", c.ArrivalAt, c.RemainingStops
			}
		}
	}
	if now.Unix() >= s.ExpiresAt {
		content.Status, content.ArrivalAt, content.RemainingStops = "expired", nil, nil
		s.Ended = true
	} else if allEnded {
		content.Status = "finished"
		s.Ended = true
	}
	s.Content = content
}

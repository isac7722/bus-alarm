package server

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestLiveGroupKeepsZeroETAUntilFirstBusPasses(t *testing.T) {
	now := time.Now().Truncate(time.Second)
	s := LiveSession{ExpiresAt: now.Add(time.Hour).Unix()}
	for i, id := range []string{"first", "second", "missing"} {
		child := LiveSession{RouteID: id, ExpiresAt: s.ExpiresAt}
		snapshot := LiveSnapshot{UpdatedAt: now, Buses: map[string][]LiveBus{}}
		if i < 2 {
			snapshot.Buses[id] = []LiveBus{liveBus(now, id, 60+i*120)}
		}
		child.advance(snapshot, now)
		s.Routes = append(s.Routes, child)
	}
	s.aggregate(now)
	if s.Ended || len(s.Content.Routes) != 3 || *s.Content.ArrivalAt != float64(now.Add(time.Minute).Unix()) {
		t.Fatal(s)
	}
	s.Routes[0].advance(LiveSnapshot{now, map[string][]LiveBus{"first": {liveBus(now, "first", 0)}}}, now)
	s.aggregate(now)
	if s.Ended || s.Content.Routes[0].Content.Status != "waiting" || *s.Content.ArrivalAt != float64(now.Unix()) {
		t.Fatal(s)
	}
	later := now.Add(time.Second)
	s.Routes[0].advance(LiveSnapshot{later, map[string][]LiveBus{"first": {liveBus(later, "following", 300)}}}, later)
	s.aggregate(later)
	if s.Ended || s.Content.Routes[0].Content.Status != "passed" || *s.Content.ArrivalAt != float64(now.Add(3*time.Minute).Unix()) {
		t.Fatal(s)
	}
	// A transport outage keeps the remaining last-known countdown.
	s.Routes[1].advance(LiveSnapshot{}, now)
	s.aggregate(now)
	if s.Ended || s.Content.Status != "waiting" || s.Content.ArrivalAt == nil {
		t.Fatal(s)
	}
	// Expiry remains terminal even with unavailable routes.
	s.aggregate(now.Add(time.Hour))
	if !s.Ended || s.Content.Status != "expired" || len(s.Content.Routes) != 3 {
		t.Fatal(s)
	}
}

func TestLiveGroupFinishesOnlyWhenAllRoutesEnd(t *testing.T) {
	now := time.Now()
	s := LiveSession{ExpiresAt: now.Add(time.Hour).Unix(), Routes: []LiveSession{
		{RouteID: "a", Ended: true, Content: LiveContent{Status: "arrived"}},
		{RouteID: "b", Ended: true, Content: LiveContent{Status: "passed"}},
	}}
	s.aggregate(now)
	if !s.Ended || s.Content.Status != "finished" {
		t.Fatal(s)
	}
	var payload struct {
		APS map[string]any `json:"aps"`
	}
	if err := json.Unmarshal(livePayload(s, now), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.APS["event"] != "end" {
		t.Fatal(payload)
	}
}

func TestLiveTargetsRejectDuplicatesAndOverflow(t *testing.T) {
	for _, targets := range [][]liveTarget{nil, {}, {{RouteID: ""}}, {{RouteID: "a"}, {RouteID: "a"}},
		{{RouteID: "a"}, {RouteID: "b"}, {RouteID: "c"}, {RouteID: "d"}, {RouteID: "e"}}} {
		if validLiveTargets(targets) {
			t.Fatal("invalid group accepted", targets)
		}
	}
	if !validLiveTargets([]liveTarget{{RouteID: "a"}, {RouteID: "b"}}) {
		t.Fatal("valid group rejected")
	}
}

func TestLiveGroupRegistrationRotationWorkerAndCancel(t *testing.T) {
	client := liveTestRedis(t)
	ctx := context.Background()
	h := testHandler()
	// The station snapshot is shared across workers in production, but each fixture owns its feed.
	snapshotKey := "liveactivity:snapshot:" + h.Service.Client.Namespace() + ":22001"
	client.Del(ctx, snapshotKey)
	t.Cleanup(func() { client.Del(ctx, snapshotKey) })
	now := time.Now().Truncate(time.Second)
	source := &fakeLiveSource{snapshot: LiveSnapshot{now, map[string][]LiveBus{
		"100100341": {liveBus(now, "bus-a", 180)}, "100100360": {liveBus(now, "bus-b", 60)},
	}}}
	pusher := &fakeLivePusher{}
	h.Live = &LiveActivities{Redis: client, Service: h.Service, Source: source, Pusher: pusher}
	secret := strings.Repeat("67", 32)
	registration := liveRegistration{StationID: "22001", PushToken: strings.Repeat("ab", 32), Environment: "sandbox",
		Routes: []liveTarget{{RouteID: "100100341"}, {RouteID: "100100360"}}}
	req := httptest.NewRequest("POST", "/", nil)
	req.Header.Set("Authorization", "Bearer "+secret)
	key, _ := liveKey(req)
	t.Cleanup(func() { client.Del(ctx, key, key+":lock") })
	request := func(method string) *httptest.ResponseRecorder {
		body, _ := json.Marshal(registration)
		req := httptest.NewRequest(method, "/api/v1/live-activities", bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+secret)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		return w
	}
	if w := request("POST"); w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	if source.calls != 1 {
		t.Fatal("group should share station snapshot", source.calls)
	}
	h.Live.process(ctx, key, map[string]LiveSnapshot{})
	if len(pusher.sessions) != 1 || len(pusher.sessions[0].Content.Routes) != 2 || *pusher.sessions[0].Content.ArrivalAt != float64(now.Add(time.Minute).Unix()) {
		t.Fatal(pusher.sessions)
	}
	registration.PushToken = strings.Repeat("cd", 32)
	if w := request("POST"); w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	raw, _ := client.Get(ctx, key).Bytes()
	var rotated LiveSession
	json.Unmarshal(raw, &rotated)
	if rotated.Routes[0].VehicleID != "bus-a" || rotated.Routes[1].VehicleID != "bus-b" || rotated.NextPushAt == 0 {
		t.Fatal("rotation reset tracking", rotated)
	}
	registration.Routes = registration.Routes[:1]
	if w := request("POST"); w.Code != 400 {
		t.Fatal("rotation changed selection", w.Code)
	}
	if w := request("DELETE"); w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	h.Live.process(ctx, key, map[string]LiveSnapshot{})
	if last := pusher.sessions[len(pusher.sessions)-1]; !last.Ended || last.Content.Status != "cancelled" {
		t.Fatal(last)
	}
	if w := request("POST"); w.Code != 409 {
		t.Fatal("cancelled group resurrected", w.Code)
	}
}

func TestV2LiveGroupValidatesBoardingAndPreservesVehicle(t *testing.T) {
	client := liveTestRedis(t)
	ctx := context.Background()
	h := testHandler()
	h.Catalog = catalogFixture(t, nil)
	pusher := &fakeLivePusher{}
	h.Live = &LiveActivities{Redis: client, Service: h.Service, Catalog: h.Catalog, Pusher: pusher}
	detail, err := h.Catalog.Detail(ctx, "gg:234000016")
	if err != nil {
		t.Fatal(err)
	}
	stop := detail.Stops[0]
	secret := strings.Repeat("68", 32)
	req := httptest.NewRequest("POST", "/", nil)
	req.Header.Set("Authorization", "Bearer "+secret)
	key, _ := liveKey(req)
	t.Cleanup(func() { client.Del(ctx, key, key+":lock") })
	registration := liveRegistration{StationID: stop.StationRef, PushToken: strings.Repeat("ab", 32), Environment: "sandbox",
		Routes: []liveTarget{{RouteID: stop.RouteRef, Boarding: &stop.BoardingSelection}}}
	send := func() *httptest.ResponseRecorder {
		body, _ := json.Marshal(registration)
		req := httptest.NewRequest("POST", "/api/v2/live-activities", bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+secret)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		return w
	}
	if w := send(); w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	h.Live.process(ctx, key, map[string]LiveSnapshot{})
	if len(pusher.sessions) != 1 || pusher.sessions[0].Routes[0].VehicleID != "gbis:bus-1" {
		t.Fatal(pusher.sessions)
	}
	registration.Routes[0].Boarding = &detail.Stops[3].BoardingSelection
	if w := send(); w.Code != 400 {
		t.Fatal("changed boarding accepted", w.Code)
	}
}

func TestLiveGroupDoesNotExtendSourceFreshness(t *testing.T) {
	now := time.Now().Truncate(time.Second)
	at := float64(now.Add(time.Minute).Unix())
	old := float64(now.Add(-60 * time.Second).Unix())
	s := LiveSession{ExpiresAt: now.Add(time.Hour).Unix(), Routes: []LiveSession{
		{RouteID: "a", Content: LiveContent{Status: "waiting", ArrivalAt: &at, UpdatedAt: old}},
		{RouteID: "b", Content: LiveContent{Status: "waiting", ArrivalAt: &at, UpdatedAt: float64(now.Unix())}},
	}}
	s.aggregate(now)
	var payload struct {
		APS map[string]any `json:"aps"`
	}
	json.Unmarshal(livePayload(s, now), &payload)
	if payload.APS["stale-date"] != at {
		t.Fatal("next presentation boundary must be at zero", payload)
	}
	// Source age is preserved even while an old ETA remains visible.
	s.Routes[0].Content.UpdatedAt = old - 60
	s.aggregate(now)
	if s.Content.UpdatedAt != old-60 {
		t.Fatal(s.Content)
	}
}

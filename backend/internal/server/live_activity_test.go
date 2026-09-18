package server

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

func liveBus(now time.Time, vehicle string, seconds int) LiveBus {
	at := stamp(now.Add(time.Duration(seconds) * time.Second))
	stops := seconds / 60
	return LiveBus{Prediction{1, &at, &seconds, &stops, "RUNNING"}, vehicle}
}
func TestLiveWaitTracksSameVehicleAndEndsOnPassage(t *testing.T) {
	now := time.Now().Truncate(time.Second)
	session := LiveSession{RouteID: "route", ExpiresAt: now.Add(time.Hour).Unix()}
	session.advance(LiveSnapshot{now, map[string][]LiveBus{"route": {liveBus(now, "first", 60), liveBus(now, "second", 300)}}}, now)
	if session.VehicleID != "first" || session.Ended || session.Content.Status != "waiting" {
		t.Fatal(session)
	}
	later := now.Add(45 * time.Second)
	session.advance(LiveSnapshot{later, map[string][]LiveBus{"route": {liveBus(later, "second", 300)}}}, later)
	if !session.Ended || session.Content.Status != "passed" {
		t.Fatal("switched to next bus", session)
	}
}
func TestLiveWaitFreshnessAndExpiry(t *testing.T) {
	now := time.Now().Truncate(time.Second)
	cases := []struct {
		name     string
		snapshot LiveSnapshot
		expires  int64
		status   string
		ended    bool
	}{
		{"zero remains imminent", LiveSnapshot{now, map[string][]LiveBus{"route": {liveBus(now, "bus", 0)}}}, now.Add(time.Hour).Unix(), "waiting", false},
		{"stale is not arrival", LiveSnapshot{now.Add(-2 * time.Minute), map[string][]LiveBus{"route": {liveBus(now, "bus", 0)}}}, now.Add(time.Hour).Unix(), "unavailable", false},
		{"upstream outage", LiveSnapshot{}, now.Add(time.Hour).Unix(), "unavailable", false},
		{"timeout during outage", LiveSnapshot{}, now.Unix(), "expired", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := LiveSession{RouteID: "route", ExpiresAt: tc.expires}
			s.advance(tc.snapshot, now)
			if s.Content.Status != tc.status || s.Ended != tc.ended {
				t.Fatal(s)
			}
		})
	}
}

func TestLiveCountdownPushesAtDisplayBoundaries(t *testing.T) {
	now := time.Unix(1000, 0)
	for _, tc := range []struct{ remaining, delay int64 }{
		{222, 10}, {181, 1}, {180, 10}, {121, 1}, {61, 1},
		{60, 10}, {39, 9}, {31, 1}, {30, 10}, {0, 10}, {-60, 10},
	} {
		at := float64(now.Unix() + tc.remaining)
		s := LiveSession{Content: LiveContent{Status: "waiting", ArrivalAt: &at}}
		s.schedulePush(now, nil)
		if s.NextPushAt != now.Unix()+tc.delay {
			t.Fatalf("remaining %d: got next push %d", tc.remaining, s.NextPushAt)
		}
	}
	// Each route can reach a boundary before the group's nearest route does.
	at := float64(now.Unix() + 61)
	s := LiveSession{Content: LiveContent{Status: "waiting", Routes: []LiveRouteContent{
		{RouteID: "next", Content: LiveContent{Status: "waiting", ArrivalAt: &at}},
	}}}
	s.schedulePush(now, nil)
	if s.NextPushAt != now.Unix()+1 {
		t.Fatal("missed route boundary", s.NextPushAt)
	}
}

func TestLiveZeroETARemainsWaitingDuringTransportOutage(t *testing.T) {
	now := time.Now().Truncate(time.Second)
	s := LiveSession{RouteID: "route", ExpiresAt: now.Add(time.Hour).Unix()}
	s.advance(LiveSnapshot{now, map[string][]LiveBus{"route": {liveBus(now, "bus", 0)}}}, now)
	s.advance(LiveSnapshot{}, now.Add(time.Minute))
	if s.Ended || s.Content.Status != "waiting" || s.Content.ArrivalAt == nil || *s.Content.ArrivalAt != float64(now.Unix()) {
		t.Fatal("zero ETA must remain imminent", s)
	}
	var payload struct {
		APS map[string]any `json:"aps"`
	}
	if err := json.Unmarshal(livePayload(s, now.Add(time.Minute)), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.APS["event"] != "update" {
		t.Fatal("zero ETA ended the activity", payload)
	}
}
func TestParseLiveSnapshotRetainsVehicleWithoutChangingPublicJSON(t *testing.T) {
	body := []byte(`<ServiceResult><msgHeader><headerCd>0</headerCd></msgHeader><msgBody><itemList><busRouteId>route</busRouteId><rtNm>07</rtNm><vehId1>vehicle-one</vehId1><traTime1>90</traTime1><staOrd>12</staOrd><sectOrd1>10</sectOrd1></itemList></msgBody></ServiceResult>`)
	snapshot, err := parseLiveSnapshot(body, testTime)
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.Buses["route"][0].VehicleID != "vehicle-one" {
		t.Fatal(snapshot)
	}
	public, err := ParseArrivals(body, testTime)
	if err != nil {
		t.Fatal(err)
	}
	encoded, _ := json.Marshal(public)
	if bytes.Contains(encoded, []byte("vehicle-one")) {
		t.Fatal("private tracking ID leaked")
	}
}
func TestAPNsTokenAndPayload(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	client := &APNsClient{key: key, keyID: "KEY", teamID: "TEAM"}
	token, err := client.token(testTime)
	if err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(token, ".")
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if len(signature) != 64 || !ecdsa.Verify(&key.PublicKey, hash[:], new(big.Int).SetBytes(signature[:32]), new(big.Int).SetBytes(signature[32:])) {
		t.Fatal("invalid ES256 signature")
	}
	same, _ := client.token(testTime.Add(49 * time.Minute))
	if token != same {
		t.Fatal("token refreshed too frequently")
	}
	renewed, _ := client.token(testTime.Add(51 * time.Minute))
	if token == renewed {
		t.Fatal("token not renewed")
	}
	at := float64(testTime.Add(time.Minute).Unix())
	var payload struct {
		APS map[string]any `json:"aps"`
	}
	if err := json.Unmarshal(livePayload(LiveSession{Ended: true, Content: LiveContent{Status: "arrived", ArrivalAt: &at}}, testTime), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.APS["event"] != "end" || payload.APS["timestamp"] != float64(testTime.Unix()) || payload.APS["dismissal-date"] != at {
		t.Fatal(payload)
	}
	content := payload.APS["content-state"].(map[string]any)
	if content["arrivalAt"] != at {
		t.Fatal("Swift contract uses Unix seconds and camelCase", content)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestAPNsRequestAndPermanentFailure(t *testing.T) {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	for _, test := range []struct {
		status          int
		reason          string
		invalid, failed bool
	}{{200, "", false, false}, {410, "Unregistered", true, false}, {400, "BadDeviceToken", true, false}, {403, "InvalidProviderToken", false, true}, {429, "TooManyRequests", false, true}, {500, "InternalServerError", false, true}} {
		t.Run(fmt.Sprint(test.status), func(t *testing.T) {
			client := &APNsClient{key: key, keyID: "KEY", teamID: "TEAM", bundleID: "com.pangjoong.BusWidget"}
			client.http = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				if r.URL.Host != "api.sandbox.push.apple.com" || r.Header.Get("apns-topic") != "com.pangjoong.BusWidget.push-type.liveactivity" || r.Header.Get("apns-push-type") != "liveactivity" || r.Header.Get("apns-priority") != "5" {
					t.Fatal(r.URL.Host, r.Header.Get("apns-topic"))
				}
				recorder := httptest.NewRecorder()
				recorder.WriteHeader(test.status)
				fmt.Fprintf(recorder, `{"reason":%q}`, test.reason)
				return recorder.Result(), nil
			})}
			invalid, err := client.Push(context.Background(), LiveSession{PushToken: strings.Repeat("ab", 32), Environment: "sandbox"})
			if invalid != test.invalid || (err != nil) != test.failed {
				t.Fatal(invalid, err)
			}
		})
	}
}

type fakeLiveSource struct {
	snapshot LiveSnapshot
	calls    int
}

func (f *fakeLiveSource) FetchLive(context.Context, string, []Route) (LiveSnapshot, error) {
	f.calls++
	return f.snapshot, nil
}

type fakeLivePusher struct {
	sessions []LiveSession
	err      error
	invalid  bool
}

func (f *fakeLivePusher) Push(_ context.Context, s LiveSession) (bool, error) {
	f.sessions = append(f.sessions, s)
	return f.invalid, f.err
}
func liveTestRedis(t *testing.T) *redis.Client {
	t.Helper()
	address := os.Getenv("TEST_REDIS_URL")
	if address == "" {
		t.Skip("requires isolated Redis integration test")
	}
	options, err := redis.ParseURL(address)
	if err != nil {
		t.Fatal(err)
	}
	client := redis.NewClient(options)
	t.Cleanup(func() { client.Close() })
	return client
}
func TestLiveActivityRegistrationWorkerCancellation(t *testing.T) {
	client := liveTestRedis(t)
	ctx := context.Background()
	h := testHandler()
	now := time.Now().Truncate(time.Second)
	source := &fakeLiveSource{snapshot: LiveSnapshot{now, map[string][]LiveBus{"100100341": {liveBus(now, "bus", 180)}}}}
	pusher := &fakeLivePusher{}
	live := &LiveActivities{Redis: client, Service: h.Service, Source: source, Pusher: pusher}
	h.Live = live
	secret := strings.Repeat("12", 32)
	keyReq := httptest.NewRequest("POST", "/", nil)
	keyReq.Header.Set("Authorization", "Bearer "+secret)
	key, _ := liveKey(keyReq)
	t.Cleanup(func() { client.Del(ctx, key, key+":lock") })
	request := func(method, secret, body string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, "/api/v1/live-activities", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+secret)
		out := httptest.NewRecorder()
		h.ServeHTTP(out, req)
		return out
	}
	body := fmt.Sprintf(`{"station_id":"22001","route_id":"100100341","push_token":%q,"environment":"sandbox"}`, strings.Repeat("ab", 32))
	if out := request("POST", "bad", body); out.Code != 401 {
		t.Fatal(out.Code, out.Body)
	}
	if out := request("POST", secret, strings.Replace(body, "100100341", "missing", 1)); out.Code != 404 {
		t.Fatal(out.Code, out.Body)
	}
	if out := request("POST", secret, body+"{}"); out.Code != 400 {
		t.Fatal(out.Code, out.Body)
	}
	if out := request("POST", secret, body); out.Code != 200 {
		t.Fatal(out.Code, out.Body)
	}
	live.process(ctx, key, map[string]LiveSnapshot{})
	if len(pusher.sessions) != 1 || pusher.sessions[0].VehicleID != "bus" {
		t.Fatal(pusher.sessions)
	}
	first, _ := client.Get(ctx, key).Bytes()
	var before LiveSession
	json.Unmarshal(first, &before)
	if out := request("POST", secret, strings.Replace(body, strings.Repeat("ab", 32), strings.Repeat("cd", 32), 1)); out.Code != 200 {
		t.Fatal(out.Code, out.Body)
	}
	second, _ := client.Get(ctx, key).Bytes()
	var rotated LiveSession
	json.Unmarshal(second, &rotated)
	if rotated.VehicleID != "bus" || rotated.ExpiresAt != before.ExpiresAt || rotated.NextPushAt != before.NextPushAt {
		t.Fatal("rotation reset tracking", rotated)
	}
	if out := request("DELETE", secret, ""); out.Code != 200 {
		t.Fatal(out.Code, out.Body)
	}
	if out := request("POST", secret, body); out.Code != 409 {
		t.Fatal("late register resurrected cancellation", out.Code)
	}
	pusher.err = fmt.Errorf("temporary failure")
	live.process(ctx, key, map[string]LiveSnapshot{})
	data, _ := client.Get(ctx, key).Bytes()
	var cancelled LiveSession
	json.Unmarshal(data, &cancelled)
	if !cancelled.Ended || cancelled.PushToken == "" {
		t.Fatal("failed end must be retried", cancelled)
	}
	cancelled.NextPushAt = 0
	data, _ = json.Marshal(cancelled)
	client.Set(ctx, key, data, time.Minute)
	pusher.err = nil
	live.process(ctx, key, map[string]LiveSnapshot{})
	data, _ = client.Get(ctx, key).Bytes()
	json.Unmarshal(data, &cancelled)
	if cancelled.PushToken != "" || !cancelled.Ended {
		t.Fatal("successful end must erase push token", cancelled)
	}
	if pusher.sessions[len(pusher.sessions)-1].Content.Status != "cancelled" {
		t.Fatal(pusher.sessions)
	}
	// An old worker cannot overwrite a newer cancellation or rotated token.
	old := LiveSession{PushToken: "old"}
	encoded, _ := json.Marshal(old)
	liveCompareSet.Run(ctx, client, []string{key}, first, encoded)
	current, _ := client.Get(ctx, key).Bytes()
	if !bytes.Equal(current, data) {
		t.Fatal("stale worker overwrote new state")
	}
	if ttl := client.TTL(ctx, key).Val(); ttl <= 0 || ttl > 65*time.Minute {
		t.Fatal("missing bounded retention", ttl)
	}
}
func TestLiveActivityDisabledAndConfig(t *testing.T) {
	h := testHandler()
	out := httptest.NewRecorder()
	h.ServeHTTP(out, httptest.NewRequest("POST", "/api/v1/live-activities", nil))
	if out.Code != 503 {
		t.Fatal(out.Code)
	}
	if err := validateAPNsConfig(Config{APNsKeyID: "KEY"}); err == nil {
		t.Fatal("partial configuration accepted")
	}
}

func TestLiveWaitDoesNotInferArrivalFromMissingOrOlderData(t *testing.T) {
	now := time.Now().Truncate(time.Second)
	initial := LiveSession{RouteID: "route", ExpiresAt: now.Add(time.Hour).Unix()}
	initial.advance(LiveSnapshot{now, map[string][]LiveBus{"route": {liveBus(now, "first", 30)}}}, now)
	missing := initial
	missing.advance(LiveSnapshot{now.Add(30 * time.Second), map[string][]LiveBus{}}, now.Add(30*time.Second))
	if missing.Ended || missing.Content.Status != "unavailable" {
		t.Fatal("missing upstream route isn't arrival", missing)
	}
	older := initial
	older.advance(LiveSnapshot{now.Add(-time.Second), map[string][]LiveBus{"route": {liveBus(now, "first", 0)}}}, now)
	if older.Ended || older.LastSeenAt != initial.LastSeenAt || older.LastArrivalAt != initial.LastArrivalAt {
		t.Fatal("older prediction replaced newer data", older)
	}
	var payload struct {
		APS map[string]any `json:"aps"`
	}
	json.Unmarshal(livePayload(initial, now.Add(60*time.Second)), &payload)
	if payload.APS["stale-date"] != float64(initial.ExpiresAt) {
		t.Fatal("elapsed ETA must not restart a countdown", payload)
	}
}

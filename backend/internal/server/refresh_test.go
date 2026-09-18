package server

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestPushRetryScheduleAndReset(t *testing.T) {
	now := time.Unix(1000, 0)
	session := LiveSession{}
	for _, seconds := range []int64{1, 3, 5, 10, 1} {
		session.schedulePush(now, errors.New("connection reset"))
		if session.NextPushAt != now.Unix()+seconds {
			t.Fatalf("retry %d: %+v", seconds, session)
		}
		now = time.Unix(session.NextPushAt, 0)
	}
	session.schedulePush(now, nil)
	if session.PushRetry != 0 || session.NextPushAt != now.Unix()+10 {
		t.Fatal(session)
	}
	for _, tc := range []struct {
		status  int
		seconds int64
	}{{429, 60}, {500, 900}, {503, 900}, {403, 900}} {
		session.schedulePush(now, &pushResponseError{Status: tc.status})
		if session.NextPushAt != now.Unix()+tc.seconds || session.PushRetry != 0 {
			t.Fatal(session)
		}
	}
}

func TestOutageRetainsETAAfterFiveMinutesWithoutClaimingArrival(t *testing.T) {
	now := time.Now().Truncate(time.Second)
	session := LiveSession{RouteID: "bus", ExpiresAt: now.Add(time.Hour).Unix()}
	session.advance(LiveSnapshot{now, map[string][]LiveBus{"bus": {liveBus(now, "vehicle", 600)}}}, now)
	original := session.Content
	session.advance(LiveSnapshot{}, now.Add(6*time.Minute))
	if session.Content.UpdatedAt != original.UpdatedAt || session.Content.ArrivalAt != original.ArrivalAt || session.Ended {
		t.Fatal(session)
	}
	session.advance(LiveSnapshot{}, now.Add(11*time.Minute))
	if session.Ended || session.Content.Status == "arrived" || session.Content.UpdatedAt != original.UpdatedAt {
		t.Fatal(session)
	}
	later := now.Add(12 * time.Minute)
	session.advance(LiveSnapshot{later, map[string][]LiveBus{"bus": {liveBus(later, "vehicle", 60)}}}, later)
	if session.VehicleID != "vehicle" || session.Content.UpdatedAt != float64(later.Unix()) || session.Ended {
		t.Fatal(session)
	}
}

func TestExpiredCachedGroupDoesNotInventNewSourceTimestamp(t *testing.T) {
	now := time.Now().Truncate(time.Second)
	old := now.Add(-10 * time.Minute)
	at := float64(now.Add(-time.Minute).Unix())
	session := LiveSession{ExpiresAt: now.Add(time.Hour).Unix(), Routes: []LiveSession{{RouteID: "route", Content: LiveContent{Status: "waiting", ArrivalAt: &at, UpdatedAt: float64(old.Unix())}}}}
	session.aggregate(now)
	if session.Content.Status != "unavailable" || session.Content.UpdatedAt != float64(old.Unix()) || session.Ended {
		t.Fatal(session)
	}
}

func TestForegroundSessionReadPreservesTrackedVehicleAndCancellation(t *testing.T) {
	redis := liveTestRedis(t)
	ctx := context.Background()
	h := testHandler()
	now := time.Now().Truncate(time.Second)
	source := &fakeLiveSource{snapshot: LiveSnapshot{now, map[string][]LiveBus{"route": {liveBus(now, "tracked", 90), liveBus(now, "next", 300)}}}}
	pusher := &fakeLivePusher{}
	h.Live = &LiveActivities{Redis: redis, Service: h.Service, Source: source, Pusher: pusher}
	secret := strings.Repeat("79", 32)
	req := httptest.NewRequest("GET", "/api/v1/live-activities", nil)
	req.Header.Set("Authorization", "Bearer "+secret)
	key, _ := liveKey(req)
	t.Cleanup(func() {
		redis.Del(ctx, key, key+":lock", "liveactivity:snapshot:"+h.Service.Client.Namespace()+":refresh-test")
	})
	session := LiveSession{StationID: "refresh-test", RouteID: "route", VehicleID: "tracked", PushToken: strings.Repeat("ab", 32), ExpiresAt: now.Add(time.Hour).Unix(), NextPushAt: now.Add(10 * time.Second).Unix()}
	raw, _ := json.Marshal(session)
	redis.Set(ctx, key, raw, time.Hour)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"status":"waiting"`) || len(pusher.sessions) != 0 {
		t.Fatal(w.Code, w.Body, pusher.sessions)
	}
	raw, _ = redis.Get(ctx, key).Bytes()
	json.Unmarshal(raw, &session)
	if session.VehicleID != "tracked" || session.Content.Revision == 0 || session.NextPushAt != now.Add(10*time.Second).Unix() {
		t.Fatal(session)
	}
	req = httptest.NewRequest("DELETE", "/api/v1/live-activities", nil)
	req.Header.Set("Authorization", "Bearer "+secret)
	h.ServeHTTP(httptest.NewRecorder(), req)
	req = httptest.NewRequest("GET", "/api/v1/live-activities", nil)
	req.Header.Set("Authorization", "Bearer "+secret)
	w = httptest.NewRecorder()
	h.ServeHTTP(w, req)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"status":"cancelled"`) {
		t.Fatal(w.Code, w.Body)
	}
}

func TestCachedArrivalWithoutProviderClockDoesNotResetETA(t *testing.T) {
	c := catalogFixture(t, func(_ string, body string) string {
		start := strings.Index(body, "<queryTime>")
		end := strings.Index(body, "</queryTime>")
		if start >= 0 && end >= 0 {
			return body[:start] + body[end+len("</queryTime>"):]
		}
		return body
	})
	c.Cache = &catalogTestCache{values: map[string][]byte{}}
	detail, err := c.Detail(context.Background(), "gg:234000016")
	if err != nil {
		t.Fatal(err)
	}
	first, err := c.BoardingLive(context.Background(), detail.Stops[0].BoardingSelection)
	if err != nil {
		t.Fatal(err)
	}
	second, err := c.BoardingLive(context.Background(), detail.Stops[0].BoardingSelection)
	if err != nil {
		t.Fatal(err)
	}
	if !first.UpdatedAt.Equal(second.UpdatedAt) || !first.Buses["gg:234000016"][0].Prediction.ArrivalAt.Equal(second.Buses["gg:234000016"][0].Prediction.ArrivalAt.Time) {
		t.Fatal("cached prediction restarted", first, second)
	}
}

func TestWorkerPersistsRetriesWithoutRepeatingArrivalLookup(t *testing.T) {
	client := liveTestRedis(t)
	ctx := context.Background()
	h := testHandler()
	now := time.Now().Truncate(time.Second)
	source := &fakeLiveSource{snapshot: LiveSnapshot{now, map[string][]LiveBus{"route": {liveBus(now, "vehicle", 600)}}}}
	pusher := &fakeLivePusher{err: errors.New("connection reset")}
	live := &LiveActivities{Redis: client, Service: h.Service, Source: source, Pusher: pusher}
	key := livePrefix + "retry-test"
	snapshotKey := "liveactivity:snapshot:" + h.Service.Client.Namespace() + ":retry-test"
	client.Del(ctx, key, snapshotKey)
	t.Cleanup(func() { client.Del(ctx, key, key+":lock", snapshotKey) })
	session := LiveSession{StationID: "retry-test", RouteID: "route", PushToken: strings.Repeat("ab", 32), ExpiresAt: now.Add(time.Hour).Unix()}
	for index, seconds := range []int64{1, 3, 5, 10} {
		session.NextPushAt = 0
		session.NextRefreshAt = 0 // A due source refresh must not run during push-only retries.
		raw, _ := json.Marshal(session)
		client.Set(ctx, key, raw, time.Hour)
		before := time.Now().Unix()
		live.process(ctx, key, map[string]LiveSnapshot{})
		raw, _ = client.Get(ctx, key).Bytes()
		json.Unmarshal(raw, &session)
		if session.NextPushAt < before+seconds || session.NextPushAt > time.Now().Unix()+seconds {
			t.Fatal(index, session)
		}
		if source.calls != 1 {
			t.Fatal("push retry repeated upstream lookup", source.calls)
		}
		if index < 3 && session.PushRetry != index+1 {
			t.Fatal(session)
		}
	}
	if session.PushRetry != 0 || len(pusher.sessions) != 4 {
		t.Fatal(session, len(pusher.sessions))
	}
}

func TestArrivalPartialFailureReturnsSuccessfulRouteAndSourceTime(t *testing.T) {
	c := catalogFixture(t, nil)
	c.HTTP = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		response, err := http.DefaultTransport.RoundTrip(r)
		if err != nil {
			return nil, err
		}
		body, _ := io.ReadAll(response.Body)
		response.Body.Close()
		text := string(body)
		if r.URL.Query().Get("routeId") == "234000017" {
			text = strings.ReplaceAll(text, "234000016", "234000017")
			if strings.Contains(r.URL.Path, "Arrival") {
				text = `<response><msgHeader><resultCode>99</resultCode></msgHeader></response>`
			}
		}
		response.Body = io.NopCloser(strings.NewReader(text))
		return response, nil
	})}
	first, err := c.Detail(context.Background(), "gg:234000016")
	if err != nil {
		t.Fatal(err)
	}
	second, err := c.Detail(context.Background(), "gg:234000017")
	if err != nil {
		t.Fatal(err)
	}
	result, err := c.Arrivals(context.Background(), SelectionRequest{first.Stops[0].StationRef, []BoardingSelection{first.Stops[0].BoardingSelection, second.Stops[0].BoardingSelection}})
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Arrivals) != 1 || result.Arrivals[0].RouteID != "gg:234000016" || len(result.FailedRouteIDs) != 1 || result.FailedRouteIDs[0] != "gg:234000017" || result.RouteUpdatedAt["gg:234000016"].IsZero() {
		t.Fatal(result)
	}
}

package server

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

func catalogFixture(t *testing.T, change func(string, string) string) *RouteCatalog {
	t.Helper()
	fixture := func(name string) string {
		b, e := os.ReadFile("testdata/routes/" + name + ".xml")
		if e != nil {
			t.Fatal(e)
		}
		return string(b)
	}
	info, stops := fixture("gg-info"), fixture("gg-stops")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body string
		switch r.URL.Path {
		case "/busrouteservice/v2/getBusRouteInfoItemv2":
			body = info
		case "/busrouteservice/v2/getBusRouteStationListv2":
			body = stops
		case "/busarrivalservice/v2/getBusArrivalItemv2":
			seq := r.URL.Query().Get("staOrder")
			seconds := "120"
			if seq == "4" {
				seconds = "600"
			}
			body = fmt.Sprintf(`<response><msgHeader><resultCode>0</resultCode><queryTime>%s</queryTime></msgHeader><msgBody><busArrivalItem><routeId>234000016</routeId><stationId>104000069</stationId><staOrder>%s</staOrder><flag>RUN</flag><vehId1>bus-%s</vehId1><predictTimeSec1>%s</predictTimeSec1></busArrivalItem></msgBody></response>`, time.Now().In(korea).Format("2006-01-02 15:04:05"), seq, seq, seconds)
		default:
			body = `<response><msgHeader><resultCode>4</resultCode></msgHeader><msgBody/></response>`
		}
		if change != nil {
			body = change(r.URL.Path, body)
		}
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(server.Close)
	return &RouteCatalog{Config: Config{GyeonggiAPIKey: "secret", GyeonggiAPIBaseURL: server.URL, APIBaseURL: server.URL + "/stationinfo"}, HTTP: server.Client()}
}
func TestCatalogPreservesVisitsAndDirections(t *testing.T) {
	c := catalogFixture(t, nil)
	d, e := c.Detail(context.Background(), "gg:234000016")
	if e != nil {
		t.Fatal(e)
	}
	if len(d.Stops) != 4 || len(d.Directions) != 2 {
		t.Fatalf("%+v", d)
	}
	a, b := d.Stops[0], d.Stops[3]
	if a.StationRef != b.StationRef || a.BoardingID == b.BoardingID || a.DirectionID == b.DirectionID || a.Station.DisplayNumber != "05267" {
		t.Fatal("visits collapsed")
	}
	for _, stop := range []MapRouteStop{a, b} {
		request := SelectionRequest{stop.StationRef, []BoardingSelection{stop.BoardingSelection}}
		result, e := c.Arrivals(context.Background(), request)
		if e != nil {
			t.Fatal(e)
		}
		want := 120
		if stop.Sequence == 4 {
			want = 600
		}
		if *result.Arrivals[0].Predictions[0].RemainingSeconds != want {
			t.Fatal("wrong direction")
		}
		snapshot, e := c.BoardingLive(context.Background(), stop.BoardingSelection)
		if e != nil {
			t.Fatal(e)
		}
		session := LiveSession{RouteID: stop.RouteRef, Boarding: &stop.BoardingSelection, ExpiresAt: time.Now().Add(time.Hour).Unix()}
		session.advance(snapshot, time.Now())
		if session.VehicleID != "gbis:bus-"+fmt.Sprint(stop.Sequence) {
			t.Fatal("wrong tracked vehicle")
		}
	}
}
func TestSelectionRejectsTamperingAndRevisionChanges(t *testing.T) {
	c := catalogFixture(t, nil)
	d, _ := c.Detail(context.Background(), "gg:234000016")
	original := d.Stops[0].BoardingSelection
	for _, mutate := range []func(*SelectionRequest){
		func(r *SelectionRequest) { r.StationRef = "gg:204000294" },
		func(r *SelectionRequest) { r.Selections[0].Sequence = 4 },
		func(r *SelectionRequest) { r.Selections[0].DirectionID = "inbound" },
		func(r *SelectionRequest) { r.Selections[0].RouteRevision = "old" },
		func(r *SelectionRequest) { r.Selections = append(r.Selections, r.Selections[0]) },
		func(r *SelectionRequest) { r.Selections = nil },
	} {
		req := SelectionRequest{original.StationRef, []BoardingSelection{original}}
		mutate(&req)
		if _, e := c.Validate(context.Background(), req); e == nil {
			t.Fatalf("accepted %+v", req)
		}
	}
	changed := catalogFixture(t, func(path, body string) string {
		if strings.Contains(path, "StationList") {
			return strings.ReplaceAll(body, "<turnSeq>3</turnSeq>", "<turnSeq>2</turnSeq>")
		}
		return body
	})
	if _, e := changed.Validate(context.Background(), SelectionRequest{original.StationRef, []BoardingSelection{original}}); e == nil {
		t.Fatal("old topology accepted")
	}
}
func TestCatalogUnknownDirectionAndMissingCoordinates(t *testing.T) {
	c := catalogFixture(t, func(path, body string) string {
		if strings.Contains(path, "StationList") {
			return strings.ReplaceAll(strings.ReplaceAll(body, "<turnSeq>3</turnSeq>", ""), "<x>127.094</x>", "<x>NaN</x>")
		}
		return body
	})
	d, e := c.Detail(context.Background(), "gg:234000016")
	if e != nil {
		t.Fatal(e)
	}
	if d.Stops[0].Selectable || d.Stops[0].Station.Longitude != nil {
		t.Fatal("invented direction or coordinates")
	}
}
func TestBoardingRejectsMismatchedArrival(t *testing.T) {
	c := catalogFixture(t, func(path, body string) string {
		if strings.Contains(path, "ArrivalItem") {
			return strings.ReplaceAll(body, "<staOrder>1</staOrder>", "<staOrder>4</staOrder>")
		}
		return body
	})
	d, _ := c.Detail(context.Background(), "gg:234000016")
	if _, e := c.BoardingLive(context.Background(), d.Stops[0].BoardingSelection); e == nil {
		t.Fatal("opposite direction accepted")
	}
}
func TestRouteHTTPValidationAndRateLimit(t *testing.T) {
	h := testHandler()
	h.Catalog = catalogFixture(t, nil)
	for _, tc := range []struct {
		method, path, body string
		status             int
	}{
		{"GET", "/api/v2/capabilities", "", 200},
		{"GET", "/api/v2/routes/gg:234000016", "", 200},
		{"GET", "/api/v2/routes/9304", "", 400},
		{"GET", "/api/v2/arrivals", "", 405},
		{"POST", "/api/v2/arrivals", `{"station_ref":"gg:104000069","selections":[],"unknown":1}`, 400},
		{"POST", "/api/v2/arrivals", `{} {}`, 400},
	} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.body)))
		if w.Code != tc.status {
			t.Fatalf("%s %d: %s", tc.path, w.Code, w.Body.String())
		}
	}
	h.Limiter = &fakeLimiter{mode: "DenyingLimiter"}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/api/v2/capabilities", nil))
	if w.Code != 429 {
		t.Fatal("v2 bypassed limiter")
	}
}
func TestMetadataCacheAndCoalescing(t *testing.T) {
	var mu sync.Mutex
	calls := 0
	c := catalogFixture(t, func(path, body string) string {
		mu.Lock()
		calls++
		mu.Unlock()
		time.Sleep(10 * time.Millisecond)
		return body
	})
	c.Cache = &catalogTestCache{values: map[string][]byte{}}
	var wg sync.WaitGroup
	for range 8 {
		wg.Go(func() {
			if _, e := c.Detail(context.Background(), "gg:234000016"); e != nil {
				t.Error(e)
			}
		})
	}
	wg.Wait()
	if calls != 4 {
		t.Fatalf("expected four coalesced metadata requests, got %d", calls)
	}
}
func TestSelectionJSONContract(t *testing.T) {
	c := catalogFixture(t, nil)
	d, _ := c.Detail(context.Background(), "gg:234000016")
	b, _ := json.Marshal(d.Stops[0])
	var obj map[string]any
	_ = json.Unmarshal(b, &obj)
	for _, key := range []string{"boarding_id", "route_ref", "route_revision", "sequence", "direction_id", "station", "selectable"} {
		if _, ok := obj[key]; !ok {
			t.Fatal("missing " + key)
		}
	}
}

func TestV2LiveSessionsKeepSeparateVisits(t *testing.T) {
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
	snapshots := map[string]LiveSnapshot{}
	for index, stop := range []MapRouteStop{detail.Stops[0], detail.Stops[3]} {
		secret := strings.Repeat(fmt.Sprintf("%02x", 80+index), 32)
		req := httptest.NewRequest("POST", "/api/v2/live-activities", nil)
		req.Header.Set("Authorization", "Bearer "+secret)
		key, _ := liveKey(req)
		t.Cleanup(func() { client.Del(ctx, key, key+":lock") })
		registration := liveRegistration{StationID: stop.StationRef, RouteID: stop.RouteRef, PushToken: strings.Repeat("ab", 32), Environment: "sandbox", Boarding: &stop.BoardingSelection}
		body, _ := json.Marshal(registration)
		req.Body = io.NopCloser(bytes.NewReader(body))
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		if w.Code != 200 {
			t.Fatalf("%d %s", w.Code, w.Body)
		}
		h.Live.process(ctx, key, snapshots)
		other := detail.Stops[3-index*3].BoardingSelection
		registration.Boarding = &other
		body, _ = json.Marshal(registration)
		req = httptest.NewRequest("POST", "/api/v2/live-activities", bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+secret)
		w = httptest.NewRecorder()
		h.ServeHTTP(w, req)
		if w.Code != 400 {
			t.Fatalf("direction rotation accepted: %d", w.Code)
		}
	}
	if len(pusher.sessions) != 2 || pusher.sessions[0].VehicleID != "gbis:bus-1" || pusher.sessions[1].VehicleID != "gbis:bus-4" {
		t.Fatalf("mixed vehicles: %+v", pusher.sessions)
	}
}

func TestSeoulArrivalFiltersExactNodeAndVisit(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("busRouteId") != "100100118" {
			t.Error("wrong route")
		}
		now := time.Now().In(korea).Format("2006-01-02 15:04:05")
		fmt.Fprintf(w, `<ServiceResult><msgHeader><headerCd>0</headerCd></msgHeader><msgBody><itemList><busRouteId>100100118</busRouteId><stId>104000069</stId><staOrd>1</staOrd><mkTm>%s</mkTm><traTime1>120</traTime1><vehId1>first</vehId1></itemList><itemList><busRouteId>100100118</busRouteId><stId>104000069</stId><staOrd>4</staOrd><mkTm>%s</mkTm><traTime1>600</traTime1><vehId1>opposite</vehId1></itemList></msgBody></ServiceResult>`, now, now)
	}))
	defer server.Close()
	c := &RouteCatalog{Config: Config{APIKey: "secret", APIBaseURL: server.URL + "/stationinfo"}, HTTP: server.Client()}
	b := BoardingSelection{RouteRef: "seoul:100100118", StationRef: "seoul:104000069", Sequence: 4}
	result, e := c.BoardingLive(context.Background(), b)
	if e != nil {
		t.Fatal(e)
	}
	if got := result.Buses[b.RouteRef][0].VehicleID; got != "seoul:opposite" {
		t.Fatal(got)
	}
	b.Sequence = 9
	if _, e := c.BoardingLive(context.Background(), b); e == nil {
		t.Fatal("missing visit accepted")
	}
}

func TestCatalogDoesNotCacheAuthenticationFailure(t *testing.T) {
	attempts := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		attempts++
		w.WriteHeader(403)
		fmt.Fprint(w, `<OpenAPI_ServiceResponse><cmmMsgHeader><returnReasonCode>30</returnReasonCode></cmmMsgHeader></OpenAPI_ServiceResponse>`)
	}))
	defer server.Close()
	c := &RouteCatalog{Config: Config{GyeonggiAPIKey: "secret", GyeonggiAPIBaseURL: server.URL}, HTTP: server.Client(), Cache: &fakeCache{}}
	for range 2 {
		if _, e := c.Detail(context.Background(), "gg:234000016"); e == nil {
			t.Fatal("auth accepted")
		}
	}
	if attempts != 2 {
		t.Fatal("cached error")
	}
}

type catalogTestCache struct {
	mu     sync.Mutex
	values map[string][]byte
}

func (c *catalogTestCache) Ping(context.Context) error { return nil }
func (c *catalogTestCache) Get(_ context.Context, key string) ([]byte, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.values[key], nil
}
func (c *catalogTestCache) Set(_ context.Context, key string, b []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.values[key] = b
	return nil
}

func TestCatalogResolvesMissingNumberAndDisablesViaPoints(t *testing.T) {
	c := catalogFixture(t, func(path, body string) string {
		if strings.Contains(path, "StationList") {
			body = strings.ReplaceAll(body, "<mobileNo>5267</mobileNo>", "")
			body = strings.ReplaceAll(body, "<stationName>중간</stationName>", "<stationName>중간(경유)</stationName>")
		}
		if strings.Contains(path, "busStationInfo") {
			return `<response><msgHeader><resultCode>0</resultCode></msgHeader><msgBody><busStationInfo><stationId>104000069</stationId><stationName>강변역</stationName><mobileNo> 05267</mobileNo><x>127.094</x><y>37.535</y></busStationInfo></msgBody></response>`
		}
		return body
	})
	d, err := c.Detail(context.Background(), "gg:234000016")
	if err != nil {
		t.Fatal(err)
	}
	if d.Stops[0].Station.DisplayNumber != "05267" {
		t.Fatal("missing number was not resolved by node ID")
	}
	if d.Stops[1].Selectable || d.Stops[1].Reason == "" {
		t.Fatal("non-boarding via point was selectable")
	}
}

func TestVerified9304GangbyeonBoarding(t *testing.T) {
	c := catalogFixture(t, func(path, body string) string {
		fixture := ""
		if strings.Contains(path, "RouteInfoItem") {
			fixture = "verified-9304-info.xml"
		}
		if strings.Contains(path, "RouteStationList") {
			fixture = "verified-9304-stops.xml"
		}
		if fixture != "" {
			b, err := os.ReadFile("testdata/routes/" + fixture)
			if err != nil {
				t.Error(err)
			}
			return string(b)
		}
		if strings.Contains(path, "busStationInfo") {
			return `<response><msgHeader><resultCode>0</resultCode></msgHeader><msgBody><busStationInfo><stationId>104000069</stationId><stationName>테크노마트앞.강변역(D)</stationName><mobileNo> 05267</mobileNo><x>127.0939333</x><y>37.5366667</y></busStationInfo></msgBody></response>`
		}
		return body
	})
	d, err := c.Detail(context.Background(), "gg:227000040")
	if err != nil {
		t.Fatal(err)
	}
	if len(d.Stops) != 50 {
		t.Fatalf("stops: %d", len(d.Stops))
	}
	s := d.Stops[24]
	if s.Sequence != 25 || s.StationRef != "gg:104000069" || s.Station.DisplayNumber != "05267" || s.DirectionID != "inbound" || !s.Selectable || s.NextStop != "현대아파트앞" {
		t.Fatalf("wrong boarding: %+v", s)
	}
	if d.Stops[0].Selectable {
		t.Fatal("garage via point cannot be boarded")
	}
}

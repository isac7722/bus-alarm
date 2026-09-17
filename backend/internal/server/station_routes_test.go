package server

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type gangbyeonRepo struct{ fakeRepo }

func (r gangbyeonRepo) Get(context.Context, string) (*Station, error) {
	return &Station{StationID: "05267", NodeID: "104000069", Name: "테크노마트앞.강변역", Longitude: 127.093802, Latitude: 37.536907}, nil
}
func (r gangbyeonRepo) Routes(context.Context, string) ([]Route, error) {
	return []Route{{"100100212", "3212"}, {"100100213", "3214"}, {"100100570", "6705A"}, {"122000006", "N6703"}}, nil
}

func gangbyeonHandler(t *testing.T, cache Cache, routesXML []byte) (*Handler, *atomic.Int32) {
	t.Helper()
	calls := &atomic.Int32{}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("arsId") != "05267" || r.URL.Query().Get("serviceKey") != "test-key+/=" {
			t.Error("incorrect station query or credential encoding")
		}
		switch r.URL.Path {
		case "/getRouteByStation":
			calls.Add(1)
			_, _ = w.Write(routesXML)
		case "/getStationByUid":
			// Only one route has an ETA. The other 17 still belong in selection.
			fmt.Fprint(w, `<ServiceResult><msgHeader><headerCd>0</headerCd></msgHeader><msgBody><itemList><busRouteId>227000040</busRouteId><rtNm>9304하남</rtNm><traTime1>120</traTime1><vehId1>test-bus</vehId1></itemList></msgBody></ServiceResult>`)
		default:
			t.Error("unexpected upstream endpoint")
			w.WriteHeader(404)
		}
	}))
	t.Cleanup(upstream.Close)
	h := testHandler()
	h.Service.Repository = gangbyeonRepo{}
	h.Service.Cache = cache
	config := h.Config
	config.APIKey = "test-key+/="
	config.APIBaseURL = upstream.URL
	h.Service.Client = &SeoulClient{config, upstream.Client(), time.Now, testLog()}
	return h, calls
}

func stationRoutesFixture(t *testing.T) []byte {
	t.Helper()
	body, err := os.ReadFile("testdata/seoul_05267_routes.xml")
	if err != nil {
		t.Fatal(err)
	}
	return body
}

func TestGangbyeonAllRoutesAndArrivalsUseSameMembership(t *testing.T) {
	h, calls := gangbyeonHandler(t, &fakeCache{}, stationRoutesFixture(t))
	for range 2 {
		out := httptest.NewRecorder()
		h.ServeHTTP(out, httptest.NewRequest("GET", "/api/v1/stations/05267", nil))
		var detail struct{ Routes []Route }
		if err := json.Unmarshal(out.Body.Bytes(), &detail); err != nil || out.Code != 200 || len(detail.Routes) != 18 {
			t.Fatal(out.Code, out.Body, err)
		}
		found := false
		for _, route := range detail.Routes {
			if route.RouteID == "227000040" && route.Name == "9304하남" {
				found = true
			}
		}
		if !found {
			t.Fatal("Gyeonggi route 9304 missing from selection")
		}
	}
	// Both an active route and an ended route omitted from the Excel are valid.
	response, err := h.Service.Arrivals(context.Background(), "05267", "227000040,234001203")
	if err != nil || len(response.Arrivals) != 2 {
		t.Fatal(response, err)
	}
	if response.Arrivals[0].RouteID != "227000040" || response.Arrivals[0].Predictions[0].RemainingSeconds == nil {
		t.Fatal("9304 arrival unavailable", response)
	}
	if response.Arrivals[1].RouteName != "1113-10광주" || len(response.Arrivals[1].Predictions) != 0 {
		t.Fatal("route without ETA lost its name", response)
	}
	if _, err := h.Service.Arrivals(context.Background(), "05267", "not-a-serving-route"); err == nil {
		t.Fatal("unrelated route accepted")
	}
	if calls.Load() != 1 {
		t.Fatal("selection and validation did not share route cache", calls.Load())
	}
}

func TestStationRouteErrorsDoNotReturnPartialCatalog(t *testing.T) {
	for _, body := range []string{
		`<ServiceResult><msgHeader><headerCd>7</headerCd></msgHeader></ServiceResult>`,
		`<ServiceResult><msgHeader><headerCd>0</headerCd></msgHeader></ServiceResult>`,
		`<ServiceResult><msgHeader><headerCd>0</headerCd></msgHeader><msgBody><itemList><busRouteId>227000040</busRouteId></itemList></msgBody></ServiceResult>`,
		`<OpenAPI_ServiceResponse><cmmMsgHeader><returnReasonCode>30</returnReasonCode></cmmMsgHeader></OpenAPI_ServiceResponse>`,
	} {
		h, _ := gangbyeonHandler(t, &fakeCache{}, []byte(body))
		if _, err := h.Service.Detail(context.Background(), "05267"); err == nil {
			t.Fatal("upstream failure silently became an incomplete route list")
		}
	}
	for _, body := range []string{`null`, `{}`, `{"routes":[{"route_id":"227000040"}]}`} {
		h, _ := gangbyeonHandler(t, &fakeCache{values: map[string][]byte{"station:05267:routes:live": []byte(body)}}, stationRoutesFixture(t))
		if _, err := h.Service.Detail(context.Background(), "05267"); err == nil {
			t.Fatal("invalid route cache accepted")
		}
	}
}

func TestStationRoutesEmptyAndDuplicates(t *testing.T) {
	empty := `<ServiceResult><msgHeader><headerCd>0</headerCd></msgHeader><msgBody/></ServiceResult>`
	routes, err := parseStationRoutes([]byte(empty))
	if err != nil || routes == nil || len(routes) != 0 {
		t.Fatal(routes, err)
	}
	item := `<itemList><busRouteId>227000040</busRouteId><busRouteNm>9304하남</busRouteNm></itemList>`
	for _, conflict := range []bool{false, true} {
		second := item
		if conflict {
			second = strings.ReplaceAll(second, "9304하남", "different")
		}
		body := strings.Replace(empty, "<msgBody/>", "<msgBody>"+item+second+"</msgBody>", 1)
		routes, err := parseStationRoutes([]byte(body))
		if conflict && err == nil || !conflict && (err != nil || len(routes) != 1) {
			t.Fatal(routes, err)
		}
	}
}

func TestGangbyeonRouteRedisCacheAndLiveRegistration(t *testing.T) {
	redis := liveTestRedis(t)
	ctx := context.Background()
	cache := &RedisStore{redis, 30, 60, 60}
	h, calls := gangbyeonHandler(t, cache, stationRoutesFixture(t))
	key := "station:05267:routes:live"
	redis.Del(ctx, key)
	t.Cleanup(func() { redis.Del(ctx, key) })
	for range 2 {
		if routes, err := h.Service.StationRoutes(ctx, "05267"); err != nil || len(routes) != 18 {
			t.Fatal(routes, err)
		}
	}
	if calls.Load() != 1 || redis.TTL(ctx, key).Val() <= 0 {
		t.Fatal("Redis route cache was not reused")
	}
	live := &LiveActivities{Redis: redis, Service: h.Service, Source: h.Service.Client.(LiveArrivalClient), Pusher: &fakeLivePusher{}}
	h.Live = live
	body := fmt.Sprintf(`{"station_id":"05267","route_id":"227000040","push_token":%q,"environment":"sandbox"}`, strings.Repeat("ab", 32))
	request := httptest.NewRequest("POST", "/api/v1/live-activities", strings.NewReader(body))
	request.Header.Set("Authorization", "Bearer "+strings.Repeat("34", 32))
	sessionKey, _ := liveKey(request)
	t.Cleanup(func() { redis.Del(ctx, sessionKey, sessionKey+":lock") })
	out := httptest.NewRecorder()
	h.ServeHTTP(out, request)
	if out.Code != 200 {
		t.Fatal("9304 cannot start Live Activity", out.Code, out.Body)
	}
	live.process(ctx, sessionKey, map[string]LiveSnapshot{})
	pusher := live.Pusher.(*fakeLivePusher)
	if len(pusher.sessions) != 1 || pusher.sessions[0].RouteID != "227000040" || pusher.sessions[0].Content.Status != "waiting" {
		t.Fatal("9304 tracking failed", pusher.sessions)
	}
}

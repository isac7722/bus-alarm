package server

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func gbisXML(body string) string {
	return `<response><msgHeader><resultCode>0</resultCode><queryTime>2026-09-17 15:44:42.024</queryTime></msgHeader><msgBody>` + body + `</msgBody></response>`
}

func gbisStationXML(tag, node, mobile string) string {
	return fmt.Sprintf(`<%s><stationId>%s</stationId><stationName>테크노마트앞.강변역(D)</stationName><mobileNo>%s</mobileNo><x>127.093802</x><y>37.536907</y></%s>`, tag, node, mobile, tag)
}

func gbisRouteXML(id, name string) string {
	return `<busRouteList><routeId>` + id + `</routeId><routeName>` + name + `</routeName><staOrder>25</staOrder></busRouteList>`
}

// Same fields and values as the 2026-09-17 live 9304 response, with a synthetic
// vehicle ID. Unlike Seoul, GBIS exposes both minute and second predictions.
const gbis9304Arrival = `<busArrivalList><stationId>104000069</stationId><routeId>227000040</routeId><routeName>9304</routeName><flag>PASS</flag><predictTime1>25</predictTime1><predictTimeSec1>1534</predictTimeSec1><locationNo1>11</locationNo1><vehId1>test-9304</vehId1><predictTime2>44</predictTime2><predictTimeSec2>2690</predictTimeSec2><locationNo2>23</locationNo2><vehId2>test-9304-next</vehId2></busArrivalList>`

func regionalHandler(t *testing.T, cache Cache) (*Handler, *atomic.Int32) {
	t.Helper()
	h, _ := gangbyeonHandler(t, cache, stationRoutesFixture(t))
	arrivalCalls := &atomic.Int32{}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		if q.Get("serviceKey") != "gbis-key+/=" || q.Get("format") != "xml" {
			t.Error("GBIS key or format encoding")
		}
		if q.Get("keyword") == "" && q.Get("stationId") != "104000069" && q.Get("stationId") != "210000239" {
			t.Error("GBIS request used ARS instead of node", q.Get("stationId"))
		}
		switch r.URL.Path {
		case gbisStationPath + "getBusStationListv2":
			fmt.Fprint(w, gbisXML(gbisStationXML("busStationList", "104000069", "5267")+gbisStationXML("busStationList", "210000239", "5267")))
		case gbisStationPath + "busStationInfov2":
			fmt.Fprint(w, gbisXML(gbisStationXML("busStationInfo", q.Get("stationId"), "5267")))
		case gbisStationPath + "getBusStationViaRouteListv2":
			fmt.Fprint(w, gbisXML(gbisRouteXML("227000040", "9304")+gbisRouteXML("299000001", "경기추가노선")))
		case gbisArrivalPath:
			arrivalCalls.Add(1)
			fmt.Fprint(w, gbisXML(strings.ReplaceAll(gbis9304Arrival, "104000069", q.Get("stationId"))))
		default:
			t.Error("unexpected GBIS endpoint", r.URL.Path)
			w.WriteHeader(404)
		}
	}))
	t.Cleanup(upstream.Close)
	config := h.Config
	config.GyeonggiAPIKey = "gbis-key+/="
	config.GyeonggiAPIBaseURL = upstream.URL
	gg := &GyeonggiClient{config, upstream.Client(), cache, func() time.Time { return time.Date(2026, 9, 17, 6, 44, 42, 0, time.UTC) }, testLog()}
	h.Service.Client = &RegionalClient{h.Service.Client.(*SeoulClient), gg, h.Service.Repository}
	return h, arrivalCalls
}

func TestRegionalSearchIdentityAndCompleteRoutes(t *testing.T) {
	h, _ := regionalHandler(t, &fakeCache{})
	result := httptest.NewRecorder()
	h.ServeHTTP(result, httptest.NewRequest("GET", "/api/v1/stations/search?q=05267", nil))
	var search struct{ Stations []StationSummary }
	if err := json.Unmarshal(result.Body.Bytes(), &search); err != nil || result.Code != 200 || len(search.Stations) != 2 {
		t.Fatal(result.Code, result.Body, err)
	}
	if search.Stations[0].StationID != "05267" || search.Stations[1].StationID != "gg:210000239" || search.Stations[1].ARSID != "05-267" {
		t.Fatal("mobile number collision merged unrelated stops", search)
	}
	for _, tc := range []struct {
		id    string
		count int
	}{{"05267", 19}, {"gg:210000239", 2}} {
		result = httptest.NewRecorder()
		h.ServeHTTP(result, httptest.NewRequest("GET", "/api/v1/stations/"+tc.id, nil))
		var detail struct {
			Station StationSummary
			Routes  []Route
		}
		if err := json.Unmarshal(result.Body.Bytes(), &detail); err != nil || result.Code != 200 || len(detail.Routes) != tc.count || detail.Station.StationID != tc.id {
			t.Fatal(result.Code, result.Body, err)
		}
		count := 0
		for _, route := range detail.Routes {
			if route.RouteID == "227000040" {
				count++
			}
		}
		if count != 1 {
			t.Fatal("9304 duplicated or absent", detail.Routes)
		}
	}
}

func TestRegionalArrivalConversionMembershipAndCache(t *testing.T) {
	h, calls := regionalHandler(t, &fakeCache{})
	for range 2 {
		response, err := h.Service.Arrivals(context.Background(), "05267", "227000040,299000001")
		if err != nil || len(response.Arrivals) != 2 {
			t.Fatal(response, err)
		}
		p := response.Arrivals[0].Predictions[0]
		if p.RemainingSeconds == nil || *p.RemainingSeconds != 1534 || *p.RemainingStops != 11 || p.ArrivalAt.Unix() != time.Date(2026, 9, 17, 6, 44, 42, 0, time.UTC).Unix()+1534 {
			t.Fatal("GBIS seconds/clock not used", p)
		}
		if response.Arrivals[1].RouteName != "경기추가노선" || len(response.Arrivals[1].Predictions) != 0 {
			t.Fatal("route without ETA missing", response)
		}
	}
	if calls.Load() != 1 {
		t.Fatal("arrival cache bypassed", calls.Load())
	}
	if _, err := h.Service.Arrivals(context.Background(), "05267", "299999999"); err == nil {
		t.Fatal("unrelated route accepted")
	}
	response, err := h.Service.Arrivals(context.Background(), "gg:210000239", "227000040")
	if err != nil || response.Station.StationID != "gg:210000239" {
		t.Fatal(response, err)
	}
}

func TestGBISPredictionStatesAndFallback(t *testing.T) {
	for _, tc := range []struct {
		flag, sec, minute, vehicle, status string
		seconds                            int
	}{
		{"RUN", "125", "3", "bus", "RUNNING", 125},
		{"PASS", "", "3", "bus", "RUNNING", 180},
		{"RUN", "0", "0", "bus", "RUNNING", 0},
		{"RUN", "0", "0", "0", "NOT_AVAILABLE", -1},
		{"RUN", "-1", "-1", "bus", "NOT_AVAILABLE", -1},
		{"WAIT", "125", "3", "bus", "WAITING", -1},
		{"STOP", "125", "3", "bus", "NOT_AVAILABLE", -1},
	} {
		root, err := decodeGBIS([]byte(gbisXML(fmt.Sprintf(`<busArrivalList><flag>%s</flag><predictTimeSec1>%s</predictTimeSec1><predictTime1>%s</predictTime1><vehId1>%s</vehId1></busArrivalList>`, tc.flag, tc.sec, tc.minute, tc.vehicle))))
		if err != nil {
			t.Fatal(err)
		}
		p := parseGBISPrediction(root.descendants("busArrivalList")[0], 1, time.Now()).Prediction
		if p.VehicleStatus != tc.status || tc.seconds < 0 && (p.ArrivalAt != nil || p.RemainingSeconds != nil) || tc.seconds >= 0 && (p.RemainingSeconds == nil || *p.RemainingSeconds != tc.seconds) {
			t.Fatal(tc, p)
		}
	}
}

func TestGBISErrorsAndEmptyResponse(t *testing.T) {
	for _, body := range []string{
		`<response><msgHeader><resultCode>30</resultCode></msgHeader></response>`,
		`<OpenAPI_ServiceResponse><cmmMsgHeader><returnReasonCode>30</returnReasonCode></cmmMsgHeader></OpenAPI_ServiceResponse>`,
		`<response><msgBody/></response>`,
		gbisXML("") + `<extra/>`,
	} {
		if _, err := decodeGBIS([]byte(body)); err == nil {
			t.Fatal("invalid GBIS response accepted", body)
		}
	}
	root, err := decodeGBIS([]byte(`<response><msgHeader><resultCode>4</resultCode></msgHeader></response>`))
	if err != nil || len(root.descendants("busArrivalList")) != 0 {
		t.Fatal(root, err)
	}
	for _, id := range []string{"gg:210000239", "05267"} {
		if !stationIDValid(id) {
			t.Fatal(id)
		}
	}
	for _, id := range []string{"gg:05267", "gg:000000000", "gg:２１００００２３９", "gg:../foo"} {
		if stationIDValid(id) {
			t.Fatal(id)
		}
	}
}

func TestGBISHTTPErrorRedaction(t *testing.T) {
	key := "secret-gbis-key+/="
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(403); fmt.Fprint(w, key) }))
	defer upstream.Close()
	var logs bytes.Buffer
	c := &GyeonggiClient{Config: Config{GyeonggiAPIKey: key, GyeonggiAPIBaseURL: upstream.URL}, HTTP: upstream.Client(), Cache: &fakeCache{}, Now: time.Now, Log: slog.New(slog.NewJSONHandler(&logs, nil))}
	_, err := c.FetchRoutes(context.Background(), "104000069")
	if err == nil || strings.Contains(err.Error()+logs.String(), key) {
		t.Fatal("error leaked key or was ignored")
	}
	upstream.Close()
	_, err = c.FetchRoutes(context.Background(), "104000069")
	if err == nil || strings.Contains(err.Error()+logs.String(), "secret-gbis-key") {
		t.Fatal("transport error leaked key")
	}
}

func TestRegionalRedisAndLiveRegistration(t *testing.T) {
	redis := liveTestRedis(t)
	ctx := context.Background()
	redis.FlushDB(ctx)
	cache := &RedisStore{redis, 30, 60, 60}
	h, _ := regionalHandler(t, cache)
	client := h.Service.Client.(*RegionalClient)
	// Registration requires a fresh prediction, independent of fixture date.
	client.Gyeonggi.Now = time.Now
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case gbisStationPath + "busStationInfov2":
			fmt.Fprint(w, gbisXML(gbisStationXML("busStationInfo", "210000239", "5267")))
		case gbisStationPath + "getBusStationViaRouteListv2":
			fmt.Fprint(w, gbisXML(gbisRouteXML("227000040", "9304")))
		case gbisArrivalPath:
			fmt.Fprint(w, strings.ReplaceAll(strings.ReplaceAll(gbisXML(gbis9304Arrival), "104000069", "210000239"), "2026-09-17 15:44:42.024", time.Now().In(korea).Format("2006-01-02 15:04:05")))
		}
	}))
	defer upstream.Close()
	client.Gyeonggi.Config.GyeonggiAPIBaseURL = upstream.URL
	live := &LiveActivities{Redis: redis, Service: h.Service, Source: client, Pusher: &fakeLivePusher{}}
	h.Live = live
	body := fmt.Sprintf(`{"station_id":"gg:210000239","route_id":"227000040","push_token":%q,"environment":"sandbox"}`, strings.Repeat("ab", 32))
	req := httptest.NewRequest("POST", "/api/v1/live-activities", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+strings.Repeat("56", 32))
	out := httptest.NewRecorder()
	h.ServeHTTP(out, req)
	if out.Code != 200 {
		t.Fatal(out.Code, out.Body)
	}
	key, _ := liveKey(req)
	t.Cleanup(func() { redis.Del(ctx, key, key+":lock") })
	live.process(ctx, key, map[string]LiveSnapshot{})
	pusher := live.Pusher.(*fakeLivePusher)
	if len(pusher.sessions) != 1 || pusher.sessions[0].VehicleID != "gbis:test-9304" || pusher.sessions[0].Content.Status != "waiting" {
		t.Fatal(pusher.sessions)
	}
	if redis.TTL(ctx, "station:gg:210000239:routes:live-gbis-v1").Val() <= 0 {
		t.Fatal("regional route cache missing TTL")
	}
}

package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"
)

var testTime = time.Date(2026, 8, 12, 0, 27, 0, 0, time.UTC)

func testLog() *slog.Logger { return slog.New(slog.NewJSONHandler(io.Discard, nil)) }

type fakeRepo struct{ err error }

func (r fakeRepo) Ping(context.Context) error { return r.err }
func (r fakeRepo) Get(_ context.Context, id string) (*Station, error) {
	if r.err != nil {
		return nil, r.err
	}
	if id != "22001" {
		return nil, nil
	}
	return &Station{"22001", "121000001", "강남역", 127.0276, 37.4979}, nil
}
func (r fakeRepo) Search(ctx context.Context, q string) ([]Station, error) {
	s, err := r.Get(ctx, "22001")
	if err != nil {
		return nil, err
	}
	if strings.Contains(s.Name, q) {
		return []Station{*s}, nil
	}
	return []Station{}, nil
}
func (r fakeRepo) Routes(context.Context, string) ([]Route, error) {
	return []Route{{"100100341", "341"}, {"100100360", "360"}}, r.err
}

type fakeCache struct {
	values map[string][]byte
	err    error
}

func (c *fakeCache) Ping(context.Context) error                        { return c.err }
func (c *fakeCache) Get(_ context.Context, key string) ([]byte, error) { return c.values[key], c.err }
func (c *fakeCache) Set(_ context.Context, key string, b []byte) error {
	if c.err != nil {
		return c.err
	}
	if c.values == nil {
		c.values = map[string][]byte{}
	}
	c.values[key] = append([]byte{}, b...)
	return nil
}

type fakeClient struct{ calls int }

func (c *fakeClient) Namespace() string { return "live" }
func (c *fakeClient) Fetch(context.Context, string, []Route) (ArrivalsResponse, error) {
	c.calls++
	seconds, stops := 180, 2
	at := stamp(testTime.Add(180 * time.Second))
	return ArrivalsResponse{UpdatedAt: stamp(testTime), FetchedAt: stamp(testTime), Arrivals: []RouteArrival{{"100100341", "341", []Prediction{{1, &at, &seconds, &stops, "RUNNING"}}}}}, nil
}

type fakeLimiter struct{ mode, identity string }

func (l *fakeLimiter) Check(_ context.Context, id string) (LimitResult, error) {
	l.identity = id
	switch l.mode {
	case "FailingLimiter":
		return LimitResult{}, cacheError()
	case "DenyingLimiter":
		return LimitResult{false, 0, 42}, nil
	}
	return LimitResult{true, 59, 60}, nil
}
func testHandler() *Handler {
	config, _ := parseConfig(map[string]string{})
	config.CORSOrigins = []string{"https://allowed.example"}
	return &Handler{config, &Service{fakeRepo{}, &fakeCache{}, &fakeClient{}, testLog()}, &fakeLimiter{}, testLog()}
}
func equalJSON(t *testing.T, a, b []byte) {
	t.Helper()
	var av, bv any
	if err := json.Unmarshal(a, &av); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, &bv); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(av, bv) {
		t.Fatalf("JSON mismatch\ngot: %s\nwant: %s", a, b)
	}
}
func TestPythonHTTPParity(t *testing.T) {
	b, err := os.ReadFile("testdata/python_http.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		Method, Path, Limiter string
		Headers               map[string]string
		Status                int
		ResponseHeaders       map[string]string `json:"response_headers"`
		Body                  string
	}
	if err := json.Unmarshal(b, &cases); err != nil {
		t.Fatal(err)
	}
	for i, c := range cases {
		t.Run(fmt.Sprintf("%02d_%s_%s", i, c.Method, c.Path), func(t *testing.T) {
			h := testHandler()
			h.Limiter = &fakeLimiter{mode: c.Limiter}
			req := httptest.NewRequest(c.Method, "http://test"+c.Path, nil)
			for k, v := range c.Headers {
				req.Header.Set(k, v)
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, req)
			if w.Code != c.Status {
				t.Fatalf("status %d want %d: %s", w.Code, c.Status, w.Body.String())
			}
			for k, v := range c.ResponseHeaders {
				if w.Header().Get(k) != v {
					t.Errorf("header %s: %q want %q", k, w.Header().Get(k), v)
				}
			}
			for k := range w.Header() {
				lower := strings.ToLower(k)
				if lower == "vary" || strings.HasPrefix(lower, "access-control-") {
					if _, ok := c.ResponseHeaders[lower]; !ok {
						t.Errorf("extra header %s", k)
					}
				}
			}
			if c.Method == "HEAD" {
				return
			}
			if strings.HasPrefix(c.ResponseHeaders["content-type"], "application/json") {
				equalJSON(t, w.Body.Bytes(), []byte(c.Body))
			} else if w.Body.String() != c.Body {
				t.Fatal("response body mismatch")
			}
		})
	}
}
func TestPythonXMLParity(t *testing.T) {
	b, err := os.ReadFile("testdata/python_xml.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		Name, XML string
		Status    int
		Body      json.RawMessage
	}
	if err := json.Unmarshal(b, &cases); err != nil {
		t.Fatal(err)
	}
	for _, c := range cases {
		t.Run(c.Name, func(t *testing.T) {
			response, err := ParseArrivals([]byte(c.XML), testTime.Add(123400*time.Microsecond))
			var got []byte
			if c.Status != 200 {
				var e *AppError
				if !errors.As(err, &e) || e.Status != c.Status {
					t.Fatalf("error %v", err)
				}
				got, _ = json.Marshal(map[string]any{"error": e})
			} else {
				if err != nil {
					t.Fatal(err)
				}
				response.Station = ArrivalStation{"22001", "강남역"}
				got, err = json.Marshal(response)
				if err != nil {
					t.Fatal(err)
				}
			}
			equalJSON(t, got, c.Body)
		})
	}
}
func TestArrivalCacheAndNamespace(t *testing.T) {
	h := testHandler()
	s := h.Service
	ctx := context.Background()
	first, err := s.Arrivals(ctx, "22001", "100100360,100100341")
	if err != nil {
		t.Fatal(err)
	}
	second, err := s.Arrivals(ctx, "22001", "100100341")
	if err != nil {
		t.Fatal(err)
	}
	if first.Arrivals[0].RouteID != "100100341" || len(first.Arrivals[1].Predictions) != 0 || len(second.Arrivals) != 1 || s.Client.(*fakeClient).calls != 1 {
		t.Fatal("cache/filter ordering changed")
	}
	s.Client = &MockClient{func() time.Time { return testTime }, testLog()}
	mock, err := s.Arrivals(ctx, "22001", "")
	if err != nil || len(mock.Arrivals) != 2 {
		t.Fatalf("mock cache isolation: %v", err)
	}
	if len(s.Cache.(*fakeCache).values) != 2 {
		t.Fatal("namespaces collided")
	}
	for i, a := range mock.Arrivals {
		if len(a.Predictions) != 2 || *a.Predictions[0].RemainingSeconds != 90+i*75 || *a.Predictions[1].RemainingStops != 6+i {
			t.Fatal("mock predictions changed")
		}
	}
}
func TestFailureResponsesAndRemovedDocs(t *testing.T) {
	for _, path := range []string{"/docs", "/redoc", "/openapi.json"} {
		h := testHandler()
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
		if w.Code != 404 {
			t.Fatal(path, w.Code)
		}
	}
	for _, path := range []string{"/health", "/api/v1/stations/search?q=a"} {
		h := testHandler()
		h.Service.Repository = fakeRepo{errors.New("db failure")}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
		if w.Code != 500 || !strings.Contains(w.Body.String(), "INTERNAL_SERVER_ERROR") {
			t.Fatal(w.Code, w.Body.String())
		}
	}
	h := testHandler()
	h.Service.Cache = &fakeCache{err: cacheError()}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/privacy", nil))
	if w.Code != 200 {
		t.Fatal("privacy requires cache")
	}
}
func TestConfiguration(t *testing.T) {
	c, err := parseConfig(map[string]string{})
	if err != nil || c.MockArrivals || c.CacheTTL != 30 || c.RateRequests != 60 || c.HTTPTimeout != 5*time.Second {
		t.Fatal(c, err)
	}
	for k, v := range map[string]string{"CACHE_TTL_SECONDS": "301", "HTTP_TIMEOUT_SECONDS": "0", "RATE_LIMIT_REQUESTS": "0", "RATE_LIMIT_WINDOW_SECONDS": "-1", "MOCK_ARRIVALS": "maybe", "CORS_ORIGINS": "null"} {
		if _, err := parseConfig(map[string]string{k: v}); err == nil {
			t.Errorf("accepted %s", k)
		}
	}
	c, err = parseConfig(map[string]string{"MOCK_ARRIVALS": "yes", "SEOUL_BUS_API_BASE_URL": "http://example///", "CACHE_TTL_SECONDS": "30.0"})
	if err != nil || !c.MockArrivals || c.APIBaseURL != "http://example" {
		t.Fatal(c, err)
	}
	if databaseURL("postgresql+asyncpg://host/db") != "postgresql://host/db" {
		t.Fatal("legacy DSN")
	}
}
func TestUpstreamTransportErrorsAndKeyRedaction(t *testing.T) {
	for _, status := range []int{200, 302, 500} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			var logs bytes.Buffer
			key := "test-api-key+/="
			up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Query().Get("serviceKey") != key || r.URL.Query().Get("arsId") != "22001" {
					t.Error("query encoding")
				}
				w.WriteHeader(status)
				_, _ = w.Write([]byte("<root/>"))
			}))
			defer up.Close()
			config, _ := parseConfig(map[string]string{"SEOUL_BUS_API_KEY": key, "SEOUL_BUS_API_BASE_URL": up.URL})
			client := &SeoulClient{config, &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}, func() time.Time { return testTime }, slog.New(slog.NewJSONHandler(&logs, nil))}
			_, err := client.Fetch(context.Background(), "22001", nil)
			if status == 200 && err != nil || status != 200 && err == nil {
				t.Fatal(err)
			}
			if strings.Contains(logs.String(), "test-api-key") || strings.Contains(logs.String(), "serviceKey") || !strings.Contains(logs.String(), "22001") {
				t.Fatal("unsafe or missing logs")
			}
		})
	}
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(50 * time.Millisecond)
		_, _ = w.Write([]byte("<root/>"))
	}))
	defer up.Close()
	config, _ := parseConfig(map[string]string{"SEOUL_BUS_API_BASE_URL": up.URL})
	client := &SeoulClient{config, &http.Client{Timeout: 5 * time.Millisecond}, time.Now, testLog()}
	_, err := client.Fetch(context.Background(), "22001", nil)
	var e *AppError
	if !errors.As(err, &e) || e.Status != 504 {
		t.Fatal(err)
	}
}
func TestTimestampPrecision(t *testing.T) {
	b, _ := json.Marshal(stamp(testTime.Add(123400 * time.Microsecond)))
	if string(b) != `"2026-08-12T00:27:00.123400Z"` {
		t.Fatal(string(b))
	}
}

func TestCachedSchemaValidation(t *testing.T) {
	h := testHandler()
	response, err := h.Service.Arrivals(context.Background(), "22001", "")
	if err != nil {
		t.Fatal(err)
	}
	valid, _ := json.Marshal(response)
	for _, change := range []func(map[string]any){
		func(v map[string]any) { delete(v, "station") },
		func(v map[string]any) { v["arrivals"] = nil },
		func(v map[string]any) { delete(v["station"].(map[string]any), "name") },
		func(v map[string]any) { delete(v["arrivals"].([]any)[0].(map[string]any), "route_id") },
		func(v map[string]any) {
			a := v["arrivals"].([]any)[0].(map[string]any)
			delete(a["predictions"].([]any)[0].(map[string]any), "arrival_at")
		},
		func(v map[string]any) {
			a := v["arrivals"].([]any)[0].(map[string]any)
			a["predictions"].([]any)[0].(map[string]any)["vehicle_status"] = "bad"
		},
		func(v map[string]any) {
			a := v["arrivals"].([]any)[0].(map[string]any)
			a["predictions"].([]any)[0].(map[string]any)["remaining_seconds"] = -1
		},
	} {
		var value map[string]any
		_ = json.Unmarshal(valid, &value)
		change(value)
		b, _ := json.Marshal(value)
		var got ArrivalsResponse
		if err := decodeCached(b, &got); err == nil {
			t.Fatal("invalid cached schema accepted", string(b))
		}
	}
}
func TestEnvironmentOverridesDotEnv(t *testing.T) {
	t.Chdir(t.TempDir())
	if err := os.WriteFile(".env", []byte("MOCK_ARRIVALS=true\nAPP_NAME='From file'\nEXTRA_KEY=ignored\n"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("MOCK_ARRIVALS", "false")
	t.Setenv("APP_NAME", "From environment")
	c, err := LoadConfig()
	if err != nil || c.MockArrivals || c.AppName != "From environment" {
		t.Fatalf("configuration precedence: %v", err)
	}
}
func TestLiveFetchUsesUTC(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte("<root/>")) }))
	defer up.Close()
	config, _ := parseConfig(map[string]string{"SEOUL_BUS_API_BASE_URL": up.URL})
	c := &SeoulClient{config, http.DefaultClient, func() time.Time { return testTime.In(korea) }, testLog()}
	result, err := c.Fetch(context.Background(), "22001", nil)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(result.FetchedAt)
	if string(b) != `"2026-08-12T00:27:00Z"` {
		t.Fatal(string(b))
	}
}

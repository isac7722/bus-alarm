package server

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

const gbisStationPath = "/busstationservice/v2/"
const gbisArrivalPath = "/busarrivalservice/v2/getBusArrivalListv2"

type GyeonggiClient struct {
	Config Config
	HTTP   *http.Client
	Cache  Cache
	Now    func() time.Time
	Log    *slog.Logger
}

func gbisError() error {
	return appError("GYEONGGI_BUS_API_ERROR", "경기 버스 정보를 일시적으로 조회할 수 없습니다.", 502)
}

func gbisNodeValid(id string) bool {
	if len(id) != 9 || id == "000000000" {
		return false
	}
	for _, ch := range id {
		if ch < '0' || ch > '9' {
			return false
		}
	}
	return true
}

// Cache only successful metadata responses. Arrival data is cached by Service.
// Credentials and upstream error bodies must never appear in logs or responses.
func (c *GyeonggiClient) request(ctx context.Context, path string, params url.Values, cached bool) (xmlNode, error) {
	key := fmt.Sprintf("gbis:metadata:v1:%x", sha256.Sum256([]byte(path+"?"+params.Encode())))
	if cached {
		body, err := c.Cache.Get(ctx, key)
		if err != nil {
			return xmlNode{}, err
		}
		if body != nil {
			var entry struct {
				XML string `json:"xml"`
			}
			if err := json.Unmarshal(body, &entry); err != nil {
				return xmlNode{}, err
			}
			return decodeGBIS([]byte(entry.XML))
		}
	}
	u, err := url.Parse(c.Config.GyeonggiAPIBaseURL + path)
	if err != nil {
		return xmlNode{}, gbisError()
	}
	params.Set("serviceKey", c.Config.GyeonggiAPIKey)
	params.Set("format", "xml")
	u.RawQuery = params.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return xmlNode{}, gbisError()
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		c.Log.Error("gyeonggi_bus_http_error", "operation", path, "error_type", fmt.Sprintf("%T", err))
		var timeout net.Error
		if errors.As(err, &timeout) && timeout.Timeout() {
			return xmlNode{}, appError("GYEONGGI_BUS_API_TIMEOUT", "경기 버스 정보 조회 시간이 초과되었습니다.", 504)
		}
		return xmlNode{}, gbisError()
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 8*1024*1024+1))
	if err != nil || len(body) > 8*1024*1024 {
		return xmlNode{}, gbisError()
	}
	root, err := decodeGBIS(body)
	if err != nil {
		return xmlNode{}, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return xmlNode{}, gbisError()
	}
	if cached {
		entry, err := json.Marshal(struct {
			XML string `json:"xml"`
		}{string(body)})
		if err != nil {
			return xmlNode{}, err
		}
		if err := c.Cache.Set(ctx, key, entry); err != nil {
			return xmlNode{}, err
		}
	}
	return root, nil
}

func decodeGBIS(body []byte) (xmlNode, error) {
	root, err := decodeSeoulResponse(body)
	if err != nil {
		return xmlNode{}, gbisError()
	}
	code := firstText(root, []string{"msgHeader", "resultCode"})
	if gateway := firstText(root, []string{"cmmMsgHeader", "returnReasonCode"}); gateway == "20" || gateway == "30" || gateway == "31" {
		return xmlNode{}, appError("GYEONGGI_BUS_API_AUTH_ERROR", "경기 버스 API 인증에 실패했습니다. 서버의 인증키와 정류소·도착정보 서비스 활용 승인을 확인해 주세요.", 502)
	}
	if code == "4" {
		return xmlNode{}, nil
	} // Documented no-results response.
	if code != "0" || len(root.descendants("msgBody")) == 0 {
		return xmlNode{}, gbisError()
	}
	return root, nil
}

func parseGBISStation(item xmlNode) (Station, error) {
	id, name := item.child("stationId"), item.child("stationName")
	x, ex := strconv.ParseFloat(item.child("x"), 64)
	y, ey := strconv.ParseFloat(item.child("y"), 64)
	if !gbisNodeValid(id) || name == "" || ex != nil || ey != nil || math.IsNaN(x) || math.IsNaN(y) || x < -180 || x > 180 || y < -90 || y > 90 {
		return Station{}, gbisError()
	}
	mobile := item.child("mobileNo")
	if mobile == "0" {
		mobile = ""
	}
	if mobile != "" {
		n, err := strconv.Atoi(mobile)
		if err != nil || n < 1 || n > 99999 {
			return Station{}, gbisError()
		}
		mobile = fmt.Sprintf("%05d", n)
	}
	return Station{StationID: "gg:" + id, NodeID: id, Name: name, Longitude: x, Latitude: y, MobileNo: mobile}, nil
}

func (c *GyeonggiClient) SearchStations(ctx context.Context, keyword string) ([]Station, error) {
	root, err := c.request(ctx, gbisStationPath+"getBusStationListv2", url.Values{"keyword": {keyword}}, true)
	if err != nil {
		return nil, err
	}
	out := []Station{}
	seen := map[string]bool{}
	for _, item := range root.descendants("msgBody", "busStationList") {
		s, err := parseGBISStation(item)
		if err != nil {
			return nil, err
		}
		if !seen[s.NodeID] {
			out = append(out, s)
			seen[s.NodeID] = true
		}
	}
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i], out[j]
		am, bm := a.MobileNo == keyword || strings.HasPrefix(a.Name, keyword), b.MobileNo == keyword || strings.HasPrefix(b.Name, keyword)
		if am != bm {
			return am
		}
		if len([]rune(a.Name)) != len([]rune(b.Name)) {
			return len([]rune(a.Name)) < len([]rune(b.Name))
		}
		if a.Name != b.Name {
			return a.Name < b.Name
		}
		return a.NodeID < b.NodeID
	})
	if len(out) > 20 {
		out = out[:20]
	}
	return out, nil
}

func (c *GyeonggiClient) GetStation(ctx context.Context, node string) (*Station, error) {
	root, err := c.request(ctx, gbisStationPath+"busStationInfov2", url.Values{"stationId": {node}}, true)
	if err != nil {
		return nil, err
	}
	items := root.descendants("msgBody", "busStationInfo")
	if len(items) == 0 {
		return nil, nil
	}
	if len(items) != 1 {
		return nil, gbisError()
	}
	s, err := parseGBISStation(items[0])
	if err != nil {
		return nil, err
	}
	if s.NodeID != node {
		return nil, gbisError()
	}
	return &s, nil
}

func (c *GyeonggiClient) FetchRoutes(ctx context.Context, node string) ([]Route, error) {
	root, err := c.request(ctx, gbisStationPath+"getBusStationViaRouteListv2", url.Values{"stationId": {node}}, true)
	if err != nil {
		return nil, err
	}
	out := []Route{}
	seen := map[string]string{}
	for _, item := range root.descendants("msgBody", "busRouteList") {
		id, name := item.child("routeId"), item.child("routeName")
		if !gbisNodeValid(id) || name == "" {
			return nil, gbisError()
		}
		if previous, ok := seen[id]; ok {
			if previous != name {
				return nil, gbisError()
			}
			continue // A loop route may visit the same stop more than once.
		}
		out = append(out, Route{id, name})
		seen[id] = name
	}
	return out, nil
}

func gbisNonnegative(value string) *int {
	n, err := strconv.Atoi(value)
	if err != nil || n < 0 || n > 86400 {
		return nil
	}
	return &n
}

func parseGBISPrediction(item xmlNode, order int, now time.Time) LiveBus {
	suffix := strconv.Itoa(order)
	vehicle := item.child("vehId" + suffix)
	if vehicle == "0" {
		vehicle = ""
	}
	if vehicle == "" {
		vehicle = item.child("plateNo" + suffix)
		if vehicle == "0" {
			vehicle = ""
		}
	}
	seconds := gbisNonnegative(item.child("predictTimeSec" + suffix))
	if seconds == nil {
		if minutes := gbisNonnegative(item.child("predictTime" + suffix)); minutes != nil && *minutes <= 1440 {
			v := *minutes * 60
			seconds = &v
		}
	}
	p := Prediction{Order: order, VehicleStatus: "NOT_AVAILABLE"}
	switch item.child("flag") {
	case "WAIT":
		p.VehicleStatus = "WAITING"
	case "RUN", "PASS":
		// A default zero without a vehicle must not become a confirmed arrival.
		if seconds != nil && (*seconds > 0 || vehicle != "") {
			p.VehicleStatus = "RUNNING"
			p.RemainingSeconds = seconds
			at := stamp(now.Add(time.Duration(*seconds) * time.Second))
			p.ArrivalAt = &at
			p.RemainingStops = gbisNonnegative(item.child("locationNo" + suffix))
		}
	}
	if vehicle != "" {
		vehicle = "gbis:" + vehicle
	}
	return LiveBus{p, vehicle}
}

func (c *GyeonggiClient) FetchLive(ctx context.Context, node string, routes []Route) (LiveSnapshot, error) {
	root, err := c.request(ctx, gbisArrivalPath, url.Values{"stationId": {node}}, false)
	if err != nil {
		return LiveSnapshot{}, err
	}
	now := c.Now().UTC()
	if queryTime := firstText(root, []string{"msgHeader", "queryTime"}); queryTime != "" {
		if parsed := parseMktime(queryTime); parsed != nil {
			now = parsed.UTC()
		} else {
			return LiveSnapshot{}, gbisError()
		}
	}
	out := LiveSnapshot{UpdatedAt: now, Buses: map[string][]LiveBus{}}
	for _, r := range routes {
		out.Buses[r.RouteID] = []LiveBus{}
	}
	for _, item := range root.descendants("msgBody", "busArrivalList") {
		id := item.child("routeId")
		if !gbisNodeValid(id) {
			return LiveSnapshot{}, gbisError()
		}
		if station := item.child("stationId"); station != "" && station != node {
			return LiveSnapshot{}, gbisError()
		}
		for _, order := range []int{1, 2} {
			bus := parseGBISPrediction(item, order, now)
			if order == 1 || bus.Prediction.VehicleStatus == "RUNNING" || bus.Prediction.VehicleStatus == "WAITING" {
				out.Buses[id] = append(out.Buses[id], bus)
			}
		}
	}
	// Multiple visits of a loop route are one selectable route. Keep its next two
	// distinct vehicles ordered by ETA, rather than overwriting one direction.
	for id, buses := range out.Buses {
		sort.SliceStable(buses, func(i, j int) bool {
			a, b := buses[i].Prediction.ArrivalAt, buses[j].Prediction.ArrivalAt
			if a == nil {
				return false
			}
			if b == nil {
				return true
			}
			return a.Before(b.Time)
		})
		unique := []LiveBus{}
		seen := map[string]bool{}
		for _, bus := range buses {
			if bus.VehicleID != "" && seen[bus.VehicleID] {
				continue
			}
			seen[bus.VehicleID] = true
			bus.Prediction.Order = len(unique) + 1
			unique = append(unique, bus)
			if len(unique) == 2 {
				break
			}
		}
		out.Buses[id] = unique
	}
	return out, nil
}

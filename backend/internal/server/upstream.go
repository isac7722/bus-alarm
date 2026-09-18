package server

import (
	"bytes"
	"context"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"golang.org/x/net/html/charset"
)

type ArrivalClient interface {
	Namespace() string
	Fetch(context.Context, string, []Route) (ArrivalsResponse, error)
}
type SeoulClient struct {
	Config Config
	HTTP   *http.Client
	Now    func() time.Time
	Log    *slog.Logger
}

func (c *SeoulClient) Namespace() string { return "live" }
func (c *SeoulClient) Fetch(ctx context.Context, id string, _ []Route) (ArrivalsResponse, error) {
	body, err := c.fetchBody(ctx, id)
	if err != nil {
		return ArrivalsResponse{}, err
	}
	return ParseArrivals(body, c.Now().UTC())
}

func (c *SeoulClient) fetchBody(ctx context.Context, id string) ([]byte, error) {
	return c.fetchStationBody(ctx, id, "getStationByUid")
}

func (c *SeoulClient) fetchStationBody(ctx context.Context, id, operation string) ([]byte, error) {
	started := c.Now()
	u, err := url.Parse(c.Config.APIBaseURL + "/" + operation)
	if err != nil {
		return nil, upstreamError("버스 정보를 일시적으로 조회할 수 없습니다.")
	}
	q := u.Query()
	q.Set("serviceKey", c.Config.APIKey)
	q.Set("arsId", id)
	u.RawQuery = q.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, upstreamError("버스 정보를 일시적으로 조회할 수 없습니다.")
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, c.httpError(id, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, c.httpError(id, fmt.Errorf("HTTP status %d", resp.StatusCode))
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, c.httpError(id, err)
	}
	c.Log.Info("seoul_bus_success", "station_id", id, "latency_ms", c.Now().Sub(started).Milliseconds())
	return body, nil
}
func (c *SeoulClient) httpError(id string, err error) error {
	var timeout net.Error
	if errors.As(err, &timeout) && timeout.Timeout() {
		c.Log.Error("seoul_bus_timeout", "station_id", id)
		return appError("SEOUL_BUS_API_TIMEOUT", "버스 정보 조회 시간이 초과되었습니다.", 504)
	}
	// Never log transport errors: net/url errors contain the credential-bearing URL.
	c.Log.Error("seoul_bus_http_error", "station_id", id, "error_type", fmt.Sprintf("%T", err))
	return upstreamError("버스 정보를 일시적으로 조회할 수 없습니다.")
}

// xmlNode retains nesting so the original descendant-path fallbacks are preserved.
type xmlNode struct {
	FetchedAt time.Time // Internal fetch time; retained across cached XML decoding.
	Name      xml.Name
	Text      string
	Children  []xmlNode
}

func (n *xmlNode) UnmarshalXML(d *xml.Decoder, start xml.StartElement) error {
	n.Name = start.Name
	for {
		tok, err := d.Token()
		if err != nil {
			return err
		}
		switch v := tok.(type) {
		case xml.StartElement:
			var child xmlNode
			if err := d.DecodeElement(&child, &v); err != nil {
				return err
			}
			n.Children = append(n.Children, child)
		case xml.CharData:
			if len(n.Children) == 0 {
				n.Text += string(v)
			}
		case xml.EndElement:
			return nil
		}
	}
}
func (n xmlNode) child(name string) string {
	for _, c := range n.Children {
		if c.Name.Space == "" && c.Name.Local == name {
			return strings.TrimSpace(c.Text)
		}
	}
	return ""
}
func (n xmlNode) descendants(path ...string) []xmlNode {
	out := []xmlNode{}
	var direct func(xmlNode, []string)
	direct = func(node xmlNode, parts []string) {
		if len(parts) == 0 {
			out = append(out, node)
			return
		}
		for _, c := range node.Children {
			if c.Name.Space == "" && c.Name.Local == parts[0] {
				direct(c, parts[1:])
			}
		}
	}
	var visit func(xmlNode)
	visit = func(node xmlNode) {
		direct(node, path)
		for _, c := range node.Children {
			visit(c)
		}
	}
	visit(n)
	return out
}
func firstText(n xmlNode, paths ...[]string) string {
	for _, path := range paths {
		nodes := n.descendants(path...)
		if len(nodes) > 0 {
			if s := strings.TrimSpace(nodes[0].Text); s != "" {
				return s
			}
		}
	}
	return ""
}

var korea = time.FixedZone("KST", 9*3600)
var remainingPattern = regexp.MustCompile(`\[(\d+)번째 전\]`)

func decodeSeoulResponse(body []byte) (xmlNode, error) {
	d := xml.NewDecoder(bytes.NewReader(body))
	d.CharsetReader = charset.NewReaderLabel
	var root xmlNode
	if err := d.Decode(&root); err != nil {
		return root, upstreamError("버스 정보 응답을 처리할 수 없습니다.")
	}
	for {
		tok, err := d.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			return root, upstreamError("버스 정보 응답을 처리할 수 없습니다.")
		}
		switch v := tok.(type) {
		case xml.StartElement:
			return root, upstreamError("버스 정보 응답을 처리할 수 없습니다.")
		case xml.CharData:
			if strings.TrimSpace(string(v)) != "" {
				return root, upstreamError("버스 정보 응답을 처리할 수 없습니다.")
			}
		}
	}
	code := firstText(root, []string{"msgHeader", "headerCd"}, []string{"headerCd"})
	if code != "" && code != "0" {
		return root, upstreamError("버스 정보를 일시적으로 조회할 수 없습니다.")
	}
	return root, nil
}

func ParseArrivals(body []byte, fetched time.Time) (ArrivalsResponse, error) {
	out := ArrivalsResponse{UpdatedAt: stamp(fetched), FetchedAt: stamp(fetched), Arrivals: []RouteArrival{}}
	root, err := decodeSeoulResponse(body)
	if err != nil {
		return out, err
	}
	items := root.descendants("msgBody", "itemList")
	if len(items) == 0 {
		items = root.descendants("itemList")
	}
	var latest time.Time
	for _, item := range items {
		if t := parseMktime(item.child("mkTm")); t != nil && (latest.IsZero() || t.After(latest)) {
			latest = *t
		}
	}
	if !latest.IsZero() {
		out.UpdatedAt = stamp(latest)
	}
	for _, item := range items {
		id := item.child("busRouteId")
		if id == "" {
			return out, upstreamError("버스 정보 응답에 필수 값이 없습니다.")
		}
		name := item.child("rtNm")
		if name == "" {
			name = item.child("busRouteAbrv")
		}
		if name == "" {
			name = id
		}
		route := RouteArrival{RouteID: id, RouteName: name, Predictions: []Prediction{}}
		for order := 1; order <= 2; order++ {
			p := parsePrediction(item, order, out.UpdatedAt.Time)
			if order == 1 || p.VehicleStatus != "NOT_AVAILABLE" && p.VehicleStatus != "UNKNOWN" {
				route.Predictions = append(route.Predictions, p)
			}
		}
		out.Arrivals = append(out.Arrivals, route)
	}
	sort.SliceStable(out.Arrivals, func(i, j int) bool {
		a, b := out.Arrivals[i], out.Arrivals[j]
		if a.RouteName == b.RouteName {
			return a.RouteID < b.RouteID
		}
		return a.RouteName < b.RouteName
	})
	return out, nil
}
func parseMktime(v string) *time.Time {
	v = strings.Split(strings.TrimSpace(v), ".")[0]
	for _, layout := range []string{"2006-01-02 15:04:05", "20060102150405"} {
		if t, err := time.ParseInLocation(layout, v, korea); err == nil {
			return &t
		}
	}
	return nil
}
func nonnegative(v string) *int {
	if v == "" {
		return nil
	}
	n, err := strconv.ParseFloat(strings.TrimSpace(v), 64)
	if err != nil || math.IsNaN(n) {
		return nil
	}
	if math.IsInf(n, 0) {
		panic("infinite upstream number")
	}
	vInt := int(n)
	if vInt < 0 {
		return nil
	}
	return &vInt
}
func parsePrediction(item xmlNode, order int, updated time.Time) Prediction {
	suffix := strconv.Itoa(order)
	message := strings.ReplaceAll(item.child("arrmsg"+suffix), " ", "")
	seconds := nonnegative(item.child("traTime" + suffix))
	vehicle := item.child("vehId" + suffix)
	status := "UNKNOWN"
	switch {
	case containsAny(message, "출발대기", "운행대기", "첫차대기"):
		status = "WAITING"
		seconds = nil
	case containsAny(message, "운행종료", "정보없음", "도착정보없음", "막차운행종료"):
		status = "NOT_AVAILABLE"
	case seconds != nil && (*seconds > 0 || vehicle != "" && vehicle != "0"):
		status = "RUNNING"
	case message == "" || message == "-":
		status = "NOT_AVAILABLE"
	}
	p := Prediction{Order: order, RemainingSeconds: seconds, VehicleStatus: status}
	if seconds != nil {
		t := stamp(updated.Add(time.Duration(*seconds) * time.Second))
		p.ArrivalAt = &t
	}
	station, section := nonnegative(item.child("staOrd")), nonnegative(item.child("sectOrd"+suffix))
	if station != nil && section != nil && *station >= *section {
		n := *station - *section
		p.RemainingStops = &n
	} else if match := remainingPattern.FindStringSubmatch(message); match != nil {
		n, _ := strconv.Atoi(match[1])
		p.RemainingStops = &n
	}
	return p
}
func containsAny(s string, tokens ...string) bool {
	for _, token := range tokens {
		if strings.Contains(s, token) {
			return true
		}
	}
	return false
}

type MockClient struct {
	Now func() time.Time
	Log *slog.Logger
}

func (m *MockClient) Namespace() string { return "mock" }
func (m *MockClient) Fetch(_ context.Context, id string, routes []Route) (ArrivalsResponse, error) {
	now := m.Now().UTC().Truncate(time.Second)
	out := ArrivalsResponse{UpdatedAt: stamp(now), FetchedAt: stamp(now), Arrivals: []RouteArrival{}}
	for i, r := range routes {
		a := RouteArrival{RouteID: r.RouteID, RouteName: r.Name, Predictions: []Prediction{}}
		for order := 1; order <= 2; order++ {
			seconds := 90 + (i%4)*75 + (order-1)*450
			stops := 1 + (i % 4) + (order-1)*5
			t := stamp(now.Add(time.Duration(seconds) * time.Second))
			a.Predictions = append(a.Predictions, Prediction{order, &t, &seconds, &stops, "RUNNING"})
		}
		out.Arrivals = append(out.Arrivals, a)
	}
	m.Log.Info("mock_arrivals_generated", "station_id", id, "route_count", len(routes))
	return out, nil
}

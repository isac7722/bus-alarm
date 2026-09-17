package server

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sync/errgroup"
	"golang.org/x/sync/singleflight"
)

// V2 keeps provider identity and each visit to a stop. Legacy IDs remain untouched.
type CatalogRoute struct {
	RouteRef string `json:"route_ref"`
	Name     string `json:"name"`
	Region   string `json:"region"`
	Kind     string `json:"kind"`
	Start    string `json:"start"`
	End      string `json:"end"`
}
type MapStation struct {
	StationRef    string   `json:"station_ref"`
	Name          string   `json:"name"`
	DisplayNumber string   `json:"display_number"`
	Latitude      *float64 `json:"latitude"`
	Longitude     *float64 `json:"longitude"`
}
type BoardingSelection struct {
	BoardingID    string `json:"boarding_id"`
	RouteRef      string `json:"route_ref"`
	RouteRevision string `json:"route_revision"`
	RouteName     string `json:"route_name"`
	StationRef    string `json:"station_ref"`
	Sequence      int    `json:"sequence"`
	DirectionID   string `json:"direction_id"`
	Direction     string `json:"direction"`
}
type MapRouteStop struct {
	BoardingSelection
	Station    MapStation `json:"station"`
	NextStop   string     `json:"next_stop"`
	Selectable bool       `json:"selectable"`
	Reason     string     `json:"reason,omitempty"`
}
type RouteDirection struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}
type CatalogDetail struct {
	Route      CatalogRoute     `json:"route"`
	Revision   string           `json:"revision"`
	Directions []RouteDirection `json:"directions"`
	Stops      []MapRouteStop   `json:"stops"`
}
type SelectionRequest struct {
	StationRef string              `json:"station_ref"`
	Selections []BoardingSelection `json:"selections"`
}
type ValidatedSelection struct {
	Station    MapStation          `json:"station"`
	Selections []BoardingSelection `json:"selections"`
}
type ProviderStatus struct {
	Provider  string `json:"provider"`
	Available bool   `json:"available"`
	Message   string `json:"message,omitempty"`
	ErrorCode string `json:"error_code,omitempty"`
}
type CatalogSearch struct {
	Routes    []CatalogRoute   `json:"routes"`
	Providers []ProviderStatus `json:"providers"`
}
type BoardingOptions struct {
	Station  MapStation     `json:"station"`
	Options  []MapRouteStop `json:"options"`
	Complete bool           `json:"complete"`
	Warnings []string       `json:"warnings"`
}
type MapCoordinate struct {
	Latitude  float64 `json:"latitude"`
	Longitude float64 `json:"longitude"`
}
type RouteGeometry struct {
	Coordinates []MapCoordinate `json:"coordinates"`
	Source      string          `json:"source"`
}

type RouteCatalog struct {
	Config     Config
	HTTP       *http.Client
	Cache      Cache
	Repository Repository
	flights    singleflight.Group
}

func splitRef(ref string) (string, string, error) {
	p, id, ok := strings.Cut(ref, ":")
	if !ok || (p != "seoul" && p != "gg") || !gbisNodeValid(id) {
		return "", "", invalid()
	}
	return p, id, nil
}
func routeError() error {
	return appError("ROUTE_DATA_UNAVAILABLE", "노선 정보를 확인하지 못했습니다. API 승인과 연결 상태를 확인해 주세요.", 502)
}
func routeChanged() error {
	return appError("ROUTE_CHANGED", "노선 정보가 변경되었습니다. 방향과 정류장을 다시 선택해 주세요.", 409)
}
func (c *RouteCatalog) configured(p string) bool {
	if p == "gg" {
		return c.Config.GyeonggiAPIKey != ""
	}
	return c.Config.APIKey != ""
}

// Success-only caching, independent metadata TTL, and coalescing across HTTP and
// Live Activity callers. Cache keys never contain credentials.
func (c *RouteCatalog) request(ctx context.Context, p, path string, q url.Values, ttl time.Duration) (xmlNode, error) {
	key := fmt.Sprintf("routes:v2:%x", sha256.Sum256([]byte(p+path+q.Encode())))
	call := c.flights.DoChan(key, func() (any, error) {
		fetchCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 12*time.Second)
		defer cancel()
		if ttl > 0 && c.Cache != nil {
			raw, e := c.Cache.Get(fetchCtx, key)
			if e != nil {
				return nil, e
			}
			if raw != nil {
				var entry struct {
					XML string `json:"xml"`
				}
				if json.Unmarshal(raw, &entry) != nil {
					return nil, cacheError()
				}
				return c.decode(p, []byte(entry.XML))
			}
		}
		base, keyValue := strings.TrimSuffix(c.Config.APIBaseURL, "/stationinfo"), c.Config.APIKey
		if p == "gg" {
			base = c.Config.GyeonggiAPIBaseURL
			keyValue = c.Config.GyeonggiAPIKey
		}
		if keyValue == "" {
			return nil, routeError()
		}
		params := url.Values{}
		for k, v := range q {
			params[k] = append([]string{}, v...)
		}
		params.Set("serviceKey", keyValue)
		if p == "gg" {
			params.Set("format", "xml")
		}
		req, e := http.NewRequestWithContext(fetchCtx, "GET", base+path+"?"+params.Encode(), nil)
		if e != nil {
			return nil, routeError()
		}
		resp, e := c.HTTP.Do(req)
		if e != nil {
			return nil, routeError()
		}
		defer resp.Body.Close()
		body, e := io.ReadAll(io.LimitReader(resp.Body, 8*1024*1024+1))
		if e != nil || len(body) > 8*1024*1024 {
			return nil, routeError()
		}
		root, e := c.decode(p, body)
		if e != nil {
			return nil, e
		}
		if resp.StatusCode != 200 {
			return nil, routeError()
		}
		if ttl > 0 && c.Cache != nil {
			raw, _ := json.Marshal(map[string]string{"xml": string(body)})
			if cache, ok := c.Cache.(interface {
				SetTTL(context.Context, string, []byte, time.Duration) error
			}); ok {
				e = cache.SetTTL(fetchCtx, key, raw, ttl)
			} else {
				e = c.Cache.Set(fetchCtx, key, raw)
			}
			if e != nil {
				return nil, e
			}
		}
		return root, nil
	})
	select {
	case <-ctx.Done():
		return xmlNode{}, ctx.Err()
	case result := <-call:
		if result.Err != nil {
			return xmlNode{}, result.Err
		}
		return result.Val.(xmlNode), nil
	}
}
func (c *RouteCatalog) decode(p string, b []byte) (xmlNode, error) {
	root, err := decodeSeoulResponse(b)
	if err != nil {
		return xmlNode{}, routeError()
	}
	auth := firstText(root, []string{"cmmMsgHeader", "returnReasonCode"})
	if auth != "" {
		return xmlNode{}, appError("ROUTE_API_AUTH_ERROR", "노선 API 인증에 실패했습니다. 노선 조회 서비스 활용 승인을 확인해 주세요.", 502)
	}
	if p == "gg" {
		return decodeGBIS(b)
	}
	if firstText(root, []string{"msgHeader", "headerCd"}) != "0" || len(root.descendants("msgBody")) == 0 {
		return xmlNode{}, routeError()
	}
	return root, nil
}
func routeFromXML(p string, n xmlNode) CatalogRoute {
	if p == "gg" {
		return CatalogRoute{"gg:" + n.child("routeId"), n.child("routeName"), n.child("regionName"), n.child("routeTypeName"), n.child("startStationName"), n.child("endStationName")}
	}
	kind := map[string]string{"1": "공항", "2": "마을", "3": "간선", "4": "지선", "5": "순환", "6": "광역"}[n.child("routeType")]
	return CatalogRoute{"seoul:" + n.child("busRouteId"), n.child("busRouteNm"), "서울", kind, n.child("stStationNm"), n.child("edStationNm")}
}
func (c *RouteCatalog) Search(ctx context.Context, q string) (CatalogSearch, error) {
	q = strings.TrimSpace(q)
	out := CatalogSearch{Routes: []CatalogRoute{}, Providers: []ProviderStatus{}}
	if q == "" || len([]rune(q)) > 60 {
		return out, invalid()
	}
	for _, p := range []string{"seoul", "gg"} {
		status := ProviderStatus{Provider: p}
		path, param, item := "/busRouteInfo/getBusRouteList", "strSrch", "itemList"
		if p == "gg" {
			path, param, item = "/busrouteservice/v2/getBusRouteListv2", "keyword", "busRouteList"
		}
		root, e := c.request(ctx, p, path, url.Values{param: {q}}, 5*time.Minute)
		if e != nil {
			status.Message = "조회하지 못한 지역입니다. 다시 시도해 주세요."
			var app *AppError
			if errors.As(e, &app) {
				status.Message = app.Message
				status.ErrorCode = app.Code
			}
		} else {
			status.Available = true
			for _, n := range root.descendants("msgBody", item) {
				if p == "seoul" && (n.child("routeType") == "7" || n.child("routeType") == "8" || n.child("routeType") == "9") {
					continue
				}
				if p == "gg" && n.child("districtCd") != "2" {
					continue
				}
				r := routeFromXML(p, n)
				if _, _, e := splitRef(r.RouteRef); e != nil || r.Name == "" {
					return out, routeError()
				}
				out.Routes = append(out.Routes, r)
			}
		}
		out.Providers = append(out.Providers, status)
	}
	sort.SliceStable(out.Routes, func(i, j int) bool {
		a, b := out.Routes[i], out.Routes[j]
		if (a.Name == q) != (b.Name == q) {
			return a.Name == q
		}
		if a.Name == b.Name {
			return a.RouteRef < b.RouteRef
		}
		return a.Name < b.Name
	})
	return out, nil
}
func nonBoardingStop(name string) bool {
	return strings.Contains(name, "(경유)") || strings.Contains(name, "(미정차)")
}
func number(v string) string {
	n, e := strconv.Atoi(v)
	if e != nil || n <= 0 || n > 99999 {
		return ""
	}
	return fmt.Sprintf("%05d", n)
}
func coordinate(v string, limit float64) *float64 {
	x, e := strconv.ParseFloat(v, 64)
	if e != nil || math.IsNaN(x) || math.IsInf(x, 0) || x == 0 || math.Abs(x) > limit {
		return nil
	}
	return &x
}
func (c *RouteCatalog) Detail(ctx context.Context, ref string) (CatalogDetail, error) {
	out := CatalogDetail{Directions: []RouteDirection{}, Stops: []MapRouteStop{}}
	p, id, e := splitRef(ref)
	if e != nil {
		return out, e
	}
	infoPath, stopPath, param, infoItem, stopItem := "/busRouteInfo/getRouteInfo", "/busRouteInfo/getStaionByRoute", "busRouteId", "itemList", "itemList"
	if p == "gg" {
		infoPath, stopPath, param, infoItem, stopItem = "/busrouteservice/v2/getBusRouteInfoItemv2", "/busrouteservice/v2/getBusRouteStationListv2", "routeId", "busRouteInfoItem", "busRouteStationList"
	}
	info, e := c.request(ctx, p, infoPath, url.Values{param: {id}}, time.Hour)
	if e != nil {
		return out, e
	}
	items := info.descendants("msgBody", infoItem)
	if len(items) != 1 {
		return out, routeError()
	}
	out.Route = routeFromXML(p, items[0])
	if p == "gg" && items[0].child("districtCd") != "2" {
		out.Route.Kind = ""
	}
	if out.Route.RouteRef != ref || out.Route.Name == "" {
		return out, routeError()
	}
	root, e := c.request(ctx, p, stopPath, url.Values{param: {id}}, time.Hour)
	if e != nil {
		return out, e
	}
	seen := map[int]bool{}
	turn := 0
	for _, n := range root.descendants("msgBody", stopItem) {
		node, name, seq, mobile, x, y, direction := n.child("station"), n.child("stationNm"), n.child("seq"), n.child("arsId"), n.child("gpsX"), n.child("gpsY"), n.child("direction")
		if p == "gg" {
			node, name, seq, mobile, x, y = n.child("stationId"), n.child("stationName"), n.child("stationSeq"), n.child("mobileNo"), n.child("x"), n.child("y")
			t, _ := strconv.Atoi(n.child("turnSeq"))
			if t > 0 {
				if turn != 0 && turn != t {
					return out, routeError()
				}
				turn = t
			}
		}
		order, e := strconv.Atoi(seq)
		if e != nil || order < 1 || seen[order] || !gbisNodeValid(node) || name == "" {
			return out, routeError()
		}
		seen[order] = true
		station := MapStation{p + ":" + node, name, number(mobile), coordinate(y, 90), coordinate(x, 180)}
		out.Stops = append(out.Stops, MapRouteStop{BoardingSelection: BoardingSelection{BoardingID: ref + ":" + node + ":" + seq, RouteRef: ref, RouteName: out.Route.Name, StationRef: station.StationRef, Sequence: order, Direction: direction}, Station: station})
	}
	if len(out.Stops) == 0 {
		return out, appError("ROUTE_NOT_FOUND", "노선의 정류장 정보가 없습니다.", 404)
	}
	// Some GBIS route responses omit Seoul mobile numbers. Resolve them by the
	// exact national node ID, without guessing from stop names or coordinates.
	var metadata errgroup.Group
	metadata.SetLimit(4)
	for i := range out.Stops {
		stop := &out.Stops[i]
		if p != "gg" || stop.Station.DisplayNumber != "" || nonBoardingStop(stop.Station.Name) {
			continue
		}
		metadata.Go(func() error {
			station, err := c.station(ctx, stop.StationRef)
			if err == nil {
				stop.Station.DisplayNumber = station.DisplayNumber
			}
			return nil // Optional display metadata must not prevent route selection.
		})
	}
	_ = metadata.Wait()
	sort.Slice(out.Stops, func(i, j int) bool { return out.Stops[i].Sequence < out.Stops[j].Sequence })
	directions := map[string]bool{}
	for i := range out.Stops {
		s := &out.Stops[i]
		if p == "gg" && turn > 0 && seen[turn] {
			if s.Sequence < turn {
				s.DirectionID = "outbound"
				s.Direction = out.Route.End
			} else {
				s.DirectionID = "inbound"
				s.Direction = out.Route.Start
			}
		}
		if p == "seoul" && s.Direction != "" {
			s.DirectionID = s.Direction
		}
		s.Selectable = s.DirectionID != "" && s.Direction != ""
		if !s.Selectable {
			s.Reason = "운행 방향을 확인할 수 없어 선택할 수 없습니다."
		} else {
			s.Direction += " 방면"
			if !directions[s.DirectionID] {
				directions[s.DirectionID] = true
				out.Directions = append(out.Directions, RouteDirection{s.DirectionID, s.Direction})
			}
		}
		if nonBoardingStop(s.Station.Name) {
			s.Selectable = false
			s.Reason = "승하차하지 않는 경유 지점입니다."
		}
		if i+1 < len(out.Stops) {
			s.NextStop = out.Stops[i+1].Station.Name
		}
	}
	raw, _ := json.Marshal(out.Stops)
	out.Revision = fmt.Sprintf("%x", sha256.Sum256(raw))[:24]
	for i := range out.Stops {
		out.Stops[i].RouteRevision = out.Revision
	}
	return out, nil
}
func (c *RouteCatalog) Validate(ctx context.Context, request SelectionRequest) (ValidatedSelection, error) {
	out := ValidatedSelection{Selections: []BoardingSelection{}}
	_, node, e := splitRef(request.StationRef)
	if e != nil || len(request.Selections) < 1 || len(request.Selections) > 4 {
		return out, invalid()
	}
	seen := map[string]bool{}
	for _, b := range request.Selections {
		if seen[b.RouteRef] {
			return out, invalid()
		}
		seen[b.RouteRef] = true
		d, e := c.Detail(ctx, b.RouteRef)
		if e != nil {
			return out, e
		}
		if b.RouteRevision != d.Revision {
			return out, routeChanged()
		}
		found := false
		for _, s := range d.Stops {
			if s.BoardingID == b.BoardingID {
				_, stopNode, _ := splitRef(s.StationRef)
				if stopNode != node || b.Sequence != s.Sequence || b.DirectionID != s.DirectionID || b.StationRef != s.StationRef || !s.Selectable {
					return out, invalid()
				}
				// Cross-provider aliases require an exact national node ID AND station lookup.
				if s.StationRef != request.StationRef {
					if !c.sameStation(ctx, request.StationRef, s.Station) {
						return out, invalid()
					}
				}
				if len(out.Selections) == 0 {
					out.Station = s.Station
					out.Station.StationRef = request.StationRef
				}
				out.Selections = append(out.Selections, s.BoardingSelection)
				found = true
				break
			}
		}
		if !found {
			return out, routeChanged()
		}
	}
	return out, nil
}
func (c *RouteCatalog) station(ctx context.Context, ref string) (MapStation, error) {
	p, node, e := splitRef(ref)
	if e != nil {
		return MapStation{}, e
	}
	if p == "gg" {
		root, e := c.request(ctx, p, "/busstationservice/v2/busStationInfov2", url.Values{"stationId": {node}}, time.Hour)
		if e != nil {
			return MapStation{}, e
		}
		items := root.descendants("msgBody", "busStationInfo")
		if len(items) != 1 {
			return MapStation{}, routeError()
		}
		s, e := parseGBISStation(items[0])
		if e != nil || s.NodeID != node {
			return MapStation{}, routeError()
		}
		return MapStation{ref, s.Name, s.MobileNo, &s.Latitude, &s.Longitude}, nil
	}
	if repo, ok := c.Repository.(interface {
		GetByNode(context.Context, string) (*Station, error)
	}); ok {
		s, e := repo.GetByNode(ctx, node)
		if e != nil {
			return MapStation{}, e
		}
		if s != nil {
			return MapStation{ref, s.Name, s.StationID, &s.Latitude, &s.Longitude}, nil
		}
	}
	root, e := c.request(ctx, p, "/stationinfo/getStationByName", url.Values{"stSrch": {node}}, time.Hour)
	if e != nil {
		return MapStation{}, e
	}
	for _, n := range root.descendants("msgBody", "itemList") {
		if n.child("stId") == node {
			return MapStation{ref, n.child("stNm"), number(n.child("arsId")), coordinate(n.child("tmY"), 90), coordinate(n.child("tmX"), 180)}, nil
		}
	}
	return MapStation{}, routeError()
}
func (c *RouteCatalog) sameStation(ctx context.Context, ref string, s MapStation) bool {
	a, e := c.station(ctx, ref)
	if e != nil {
		return false
	}
	_, an, _ := splitRef(a.StationRef)
	_, sn, _ := splitRef(s.StationRef)
	return an == sn && a.Latitude != nil && s.Latitude != nil && a.Longitude != nil && s.Longitude != nil && math.Abs(*a.Latitude-*s.Latitude) < 0.0005 && math.Abs(*a.Longitude-*s.Longitude) < 0.0005
}
func (c *RouteCatalog) Options(ctx context.Context, ref string, anchor ...string) (BoardingOptions, error) {
	out := BoardingOptions{Options: []MapRouteStop{}, Warnings: []string{}, Complete: true}
	var station MapStation
	var e error
	if len(anchor) > 0 && anchor[0] != "" {
		detail, anchorErr := c.Detail(ctx, anchor[0])
		if anchorErr != nil {
			return out, anchorErr
		}
		found := false
		for _, stop := range detail.Stops {
			if stop.StationRef == ref {
				station = stop.Station
				e = nil
				found = true
				break
			}
		}
		if !found {
			return out, invalid()
		}
	} else {
		station, e = c.station(ctx, ref)
	}
	if e != nil {
		return out, e
	}
	out.Station = station
	_, node, _ := splitRef(ref)
	refs := []string{}
	for _, p := range []string{"seoul", "gg"} {
		candidate := station
		candidate.StationRef = p + ":" + node
		if candidate.StationRef != ref {
			other, e := c.station(ctx, candidate.StationRef)
			if e != nil {
				out.Complete = false
				out.Warnings = append(out.Warnings, p+" 노선 조회 실패")
				continue
			}
			if !c.sameStation(ctx, ref, other) {
				continue
			}
			candidate = other
		}
		path, param, item := "/stationinfo/getRouteByStation", "arsId", "itemList"
		value := candidate.DisplayNumber
		if p == "gg" {
			path, param, item, value = "/busstationservice/v2/getBusStationViaRouteListv2", "stationId", "busRouteList", node
		}
		if value == "" {
			out.Complete = false
			continue
		}
		root, e := c.request(ctx, p, path, url.Values{param: {value}}, 5*time.Minute)
		if e != nil {
			out.Complete = false
			continue
		}
		for _, n := range root.descendants("msgBody", item) {
			id := n.child("busRouteId")
			if p == "gg" {
				id = n.child("routeId")
			}
			if gbisNodeValid(id) {
				refs = append(refs, p+":"+id)
			}
		}
	}
	seen := map[string]bool{}
	// Bound fan-out; no claim of completeness if an upstream returns an excessive list.
	if len(refs) > 80 {
		refs = refs[:80]
		out.Complete = false
	}
	unique := []string{}
	for _, r := range refs {
		if !seen[r] {
			seen[r] = true
			unique = append(unique, r)
		}
	}
	details := make([]CatalogDetail, len(unique))
	failures := make([]error, len(unique))
	var group errgroup.Group
	group.SetLimit(4)
	for i, r := range unique {
		group.Go(func() error { details[i], failures[i] = c.Detail(ctx, r); return nil })
	}
	_ = group.Wait()
	for i, d := range details {
		if failures[i] != nil {
			out.Complete = false
			continue
		}
		if d.Route.Kind == "" {
			continue
		}
		for _, s := range d.Stops {
			_, n, _ := splitRef(s.StationRef)
			if n == node && (s.StationRef == ref || c.sameStation(ctx, ref, s.Station)) {
				out.Options = append(out.Options, s)
			}
		}
	}
	if !out.Complete {
		out.Warnings = []string{"일부 노선 정보를 확인하지 못했습니다. 전체 목록을 불러오려면 다시 시도해 주세요."}
	}
	sort.SliceStable(out.Options, func(i, j int) bool {
		a, b := out.Options[i], out.Options[j]
		if a.RouteName == b.RouteName {
			return a.BoardingID < b.BoardingID
		}
		return a.RouteName < b.RouteName
	})
	return out, nil
}
func (c *RouteCatalog) Geometry(ctx context.Context, ref string) (RouteGeometry, error) {
	out := RouteGeometry{Coordinates: []MapCoordinate{}, Source: "stops"}
	p, id, e := splitRef(ref)
	if e != nil {
		return out, e
	}
	if p == "gg" {
		root, e := c.request(ctx, p, "/busrouteservice/v2/getBusRouteLineListv2", url.Values{"routeId": {id}}, time.Hour)
		if e == nil {
			items := root.descendants("msgBody", "busRouteLineList")
			sort.Slice(items, func(i, j int) bool {
				a, _ := strconv.Atoi(items[i].child("lineSeq"))
				b, _ := strconv.Atoi(items[j].child("lineSeq"))
				return a < b
			})
			for _, n := range items {
				x, y := coordinate(n.child("x"), 180), coordinate(n.child("y"), 90)
				if x == nil || y == nil {
					return out, routeError()
				}
				out.Coordinates = append(out.Coordinates, MapCoordinate{*y, *x})
			}
			if len(out.Coordinates) > 1 {
				out.Source = "provider"
				return out, nil
			}
		}
	}
	d, e := c.Detail(ctx, ref)
	if e != nil {
		return out, e
	}
	for _, s := range d.Stops {
		if s.Station.Latitude != nil && s.Station.Longitude != nil {
			out.Coordinates = append(out.Coordinates, MapCoordinate{*s.Station.Latitude, *s.Station.Longitude})
		}
	}
	return out, nil
}

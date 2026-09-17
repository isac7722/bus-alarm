package server

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
)

// StationRouteClient lists every serving route, including routes without an ETA.
type StationRouteClient interface {
	FetchRoutes(context.Context, string) ([]Route, error)
}

func (c *SeoulClient) FetchRoutes(ctx context.Context, id string) ([]Route, error) {
	body, err := c.fetchStationBody(ctx, id, "getRouteByStation")
	if err != nil {
		return nil, err
	}
	return parseStationRoutes(body)
}

func parseStationRoutes(body []byte) ([]Route, error) {
	root, err := decodeSeoulResponse(body)
	if err != nil {
		return nil, err
	}
	if firstText(root, []string{"msgHeader", "headerCd"}, []string{"headerCd"}) != "0" || len(root.descendants("msgBody")) == 0 {
		return nil, upstreamError("버스 노선 응답을 처리할 수 없습니다.")
	}
	routes := []Route{}
	names := map[string]string{}
	for _, item := range root.descendants("msgBody", "itemList") {
		id, name := item.child("busRouteId"), item.child("busRouteNm")
		if id == "" || name == "" {
			return nil, upstreamError("버스 노선 응답에 필수 값이 없습니다.")
		}
		if previous, exists := names[id]; exists {
			if previous != name {
				return nil, upstreamError("버스 노선 응답에 중복된 노선 정보가 있습니다.")
			}
			continue
		}
		names[id] = name
		routes = append(routes, Route{id, name})
	}
	sort.Slice(routes, func(i, j int) bool {
		if routes[i].Name == routes[j].Name {
			return routes[i].RouteID < routes[j].RouteID
		}
		return routes[i].Name < routes[j].Name
	})
	return routes, nil
}

// StationRoutes shares the same authoritative route list across selection,
// arrival validation and Live Activities. Mock mode keeps the offline catalog.
func (s *Service) StationRoutes(ctx context.Context, id string) ([]Route, error) {
	client, live := s.Client.(StationRouteClient)
	if !live {
		return s.Repository.Routes(ctx, id)
	}
	key := "station:" + id + ":routes:" + s.Client.Namespace()
	cached, err := s.Cache.Get(ctx, key)
	if err != nil {
		return nil, err
	}
	if cached != nil {
		var entry struct {
			Routes []Route `json:"routes"`
		}
		if err := json.Unmarshal(cached, &entry); err != nil {
			return nil, err
		}
		routes := entry.Routes
		if routes == nil {
			return nil, fmt.Errorf("invalid cached station routes")
		}
		for _, route := range routes {
			if route.RouteID == "" || route.Name == "" {
				return nil, fmt.Errorf("invalid cached station route")
			}
		}
		return routes, nil
	}
	routes, err := client.FetchRoutes(ctx, id)
	if err != nil {
		// Returning the incomplete Excel list would hide the same missing routes.
		return nil, err
	}
	encoded, err := json.Marshal(struct {
		Routes []Route `json:"routes"`
	}{routes})
	if err != nil {
		return nil, err
	}
	if err := s.Cache.Set(ctx, key, encoded); err != nil {
		return nil, err
	}
	return routes, nil
}

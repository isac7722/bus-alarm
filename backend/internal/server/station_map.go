package server

import (
	"context"
	"math"
	"net/http"
	"strconv"
)

// Bounds are the visible map area, not a stored user location.
type StationBounds struct{ South, West, North, East float64 }
type StationMapResult struct {
	Stations  []MapStation `json:"stations"`
	Truncated bool         `json:"truncated"`
}

func stationBounds(r *http.Request) (StationBounds, error) {
	var b StationBounds
	for key, target := range map[string]*float64{"south": &b.South, "west": &b.West, "north": &b.North, "east": &b.East} {
		value, err := strconv.ParseFloat(lastQuery(r, key), 64)
		if err != nil || math.IsNaN(value) || math.IsInf(value, 0) {
			return b, invalid()
		}
		*target = value
	}
	if b.South < -90 || b.North > 90 || b.West < -180 || b.East > 180 || b.South >= b.North || b.West >= b.East {
		return b, invalid()
	}
	if b.North-b.South > 0.12 || b.East-b.West > 0.12 {
		return b, appError("MAP_AREA_TOO_LARGE", "지도를 확대해 정류장을 찾아보세요.", 400)
	}
	return b, nil
}
func (c *RouteCatalog) StationsInBounds(ctx context.Context, b StationBounds) (StationMapResult, error) {
	out := StationMapResult{Stations: []MapStation{}}
	repo, ok := c.Repository.(interface {
		InBounds(context.Context, StationBounds) ([]Station, error)
	})
	if !ok {
		return out, appError("STATION_MAP_UNAVAILABLE", "지도 정류장을 불러올 수 없습니다. 이름으로 검색해 주세요.", 503)
	}
	rows, err := repo.InBounds(ctx, b)
	if err != nil {
		return out, err
	}
	seen := map[string]bool{}
	for _, s := range rows {
		if !gbisNodeValid(s.NodeID) || nonBoardingStop(s.Name) || seen[s.NodeID] {
			continue
		}
		seen[s.NodeID] = true
		if len(out.Stations) == 200 {
			out.Truncated = true
			break
		}
		lat, lon := s.Latitude, s.Longitude
		out.Stations = append(out.Stations, MapStation{"seoul:" + s.NodeID, s.Name, s.StationID, &lat, &lon})
	}
	return out, nil
}

func (r *PostgresRepository) InBounds(ctx context.Context, b StationBounds) ([]Station, error) {
	rows, err := r.Pool.Query(ctx, `SELECT DISTINCT ON (node_id) station_id,node_id,name,longitude,latitude FROM stations
		WHERE latitude BETWEEN $1 AND $2 AND longitude BETWEEN $3 AND $4
		AND name NOT LIKE '%(경유)%' AND name NOT LIKE '%(미정차)%'
		ORDER BY node_id,station_id LIMIT 201`, b.South, b.North, b.West, b.East)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Station{}
	for rows.Next() {
		var s Station
		if err := rows.Scan(&s.StationID, &s.NodeID, &s.Name, &s.Longitude, &s.Latitude); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

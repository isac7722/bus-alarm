package server

import (
	"context"
	"fmt"
	"math"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/xuri/excelize/v2"
)

var catalogHeaders = []string{"ROUTE_ID", "노선명", "순번", "NODE_ID", "ARS_ID", "정류소명", "X좌표", "Y좌표"}

type RouteStop struct {
	RouteID   string
	Sequence  int
	StationID string
}
type Catalog struct {
	Stations []Station
	Routes   []Route
	Stops    []RouteStop
	Skipped  int
}

func ReadCatalog(path string) (Catalog, error) {
	out := Catalog{Stations: []Station{}, Routes: []Route{}, Stops: []RouteStop{}}
	f, err := excelize.OpenFile(path)
	if err != nil {
		return out, err
	}
	defer f.Close()
	rows, err := f.GetRows("Data", excelize.Options{RawCellValue: true})
	if err != nil {
		return out, fmt.Errorf("Catalog workbook must contain a 'Data' sheet: %w", err)
	}
	if len(rows) == 0 || len(rows[0]) != len(catalogHeaders) {
		return out, fmt.Errorf("Unexpected headers")
	}
	for i, h := range catalogHeaders {
		if rows[0][i] != h {
			return out, fmt.Errorf("Unexpected headers")
		}
	}
	stations := map[string]Station{}
	routes := map[string]Route{}
	stops := map[string]bool{}
	for i, row := range rows[1:] {
		rowNumber := i + 2
		if len(row) != 8 {
			return out, fmt.Errorf("Row %d has missing or malformed values", rowNumber)
		}
		for _, v := range row {
			if v == "" {
				return out, fmt.Errorf("Row %d has missing or malformed values", rowNumber)
			}
		}
		node := strings.TrimSpace(row[3])
		if !strings.HasPrefix(node, "1") {
			out.Skipped++
			continue
		}
		id := strings.Split(strings.TrimSpace(row[4]), ".")[0]
		if n := 5 - utf8.RuneCountInString(id); n > 0 {
			id = strings.Repeat("0", n) + id
		}
		routeID := strings.Split(strings.TrimSpace(row[0]), ".")[0]
		if utf8.RuneCountInString(id) != 5 || !allDigits(id) {
			return out, fmt.Errorf("Row %d has an invalid ARS_ID", rowNumber)
		}
		if utf8.RuneCountInString(node) != 9 || !allDigits(node) {
			return out, fmt.Errorf("Row %d has an invalid NODE_ID", rowNumber)
		}
		sequence, err := strconv.Atoi(strings.TrimSpace(row[2]))
		if err != nil {
			cell, _ := excelize.CoordinatesToCellName(3, rowNumber)
			kind, _ := f.GetCellType("Data", cell)
			if kind == excelize.CellTypeNumber || kind == excelize.CellTypeUnset {
				n, e := strconv.ParseFloat(row[2], 64)
				if e != nil || math.IsNaN(n) || math.IsInf(n, 0) {
					return out, fmt.Errorf("Row %d has invalid numeric values", rowNumber)
				}
				sequence = int(n)
			} else {
				return out, fmt.Errorf("Row %d has invalid numeric values", rowNumber)
			}
		}
		longitude, e1 := strconv.ParseFloat(strings.TrimSpace(row[6]), 64)
		latitude, e2 := strconv.ParseFloat(strings.TrimSpace(row[7]), 64)
		if e1 != nil || e2 != nil {
			return out, fmt.Errorf("Row %d has invalid numeric values", rowNumber)
		}
		if sequence < 1 || !(longitude >= 123 && longitude <= 133) || !(latitude >= 32 && latitude <= 40) {
			return out, fmt.Errorf("Row %d contains out-of-range data", rowNumber)
		}
		s := Station{StationID: id, NodeID: node, Name: strings.TrimSpace(row[5]), Longitude: longitude, Latitude: latitude}
		if old, ok := stations[id]; ok {
			if old != s {
				return out, fmt.Errorf("Conflicting station metadata for ARS_ID %s", id)
			}
		} else {
			out.Stations = append(out.Stations, s)
		}
		stations[id] = s
		route := Route{routeID, strings.TrimSpace(row[1])}
		if old, ok := routes[routeID]; ok {
			if old != route {
				return out, fmt.Errorf("Conflicting route metadata for route %s", routeID)
			}
		} else {
			out.Routes = append(out.Routes, route)
		}
		routes[routeID] = route
		key := fmt.Sprintf("%s:%d", routeID, sequence)
		if stops[key] {
			return out, fmt.Errorf("Duplicate route sequence at row %d", rowNumber)
		}
		stops[key] = true
		out.Stops = append(out.Stops, RouteStop{routeID, sequence, id})
	}
	if len(out.Stations) == 0 || len(out.Routes) == 0 || len(out.Stops) == 0 {
		return out, fmt.Errorf("Catalog contained no Seoul station rows")
	}
	return out, nil
}
func allDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if !unicode.IsDigit(r) {
			return false
		}
	}
	return true
}
func PersistCatalog(ctx context.Context, pool *pgxpool.Pool, c Catalog) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	for _, table := range []string{"route_stops", "routes", "stations"} {
		if _, err := tx.Exec(ctx, "DELETE FROM "+table); err != nil {
			return err
		}
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"stations"}, []string{"station_id", "node_id", "name", "longitude", "latitude"}, pgx.CopyFromSlice(len(c.Stations), func(i int) ([]any, error) {
		s := c.Stations[i]
		return []any{s.StationID, s.NodeID, s.Name, s.Longitude, s.Latitude}, nil
	})); err != nil {
		return err
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"routes"}, []string{"route_id", "name"}, pgx.CopyFromSlice(len(c.Routes), func(i int) ([]any, error) { r := c.Routes[i]; return []any{r.RouteID, r.Name}, nil })); err != nil {
		return err
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"route_stops"}, []string{"route_id", "sequence", "station_id"}, pgx.CopyFromSlice(len(c.Stops), func(i int) ([]any, error) { s := c.Stops[i]; return []any{s.RouteID, s.Sequence, s.StationID}, nil })); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

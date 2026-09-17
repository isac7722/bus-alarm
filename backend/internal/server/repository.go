package server

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Repository interface {
	Ping(context.Context) error
	Search(context.Context, string) ([]Station, error)
	Get(context.Context, string) (*Station, error)
	Routes(context.Context, string) ([]Route, error)
}
type PostgresRepository struct{ Pool *pgxpool.Pool }

func (r *PostgresRepository) Ping(ctx context.Context) error { return r.Pool.Ping(ctx) }
func (r *PostgresRepository) Get(ctx context.Context, id string) (*Station, error) {
	s := Station{}
	err := r.Pool.QueryRow(ctx, "SELECT station_id,node_id,name,longitude,latitude FROM stations WHERE station_id=$1", id).Scan(&s.StationID, &s.NodeID, &s.Name, &s.Longitude, &s.Latitude)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return &s, err
}
func (r *PostgresRepository) Search(ctx context.Context, keyword string) ([]Station, error) {
	escaped := strings.NewReplacer("%", `\%`, "_", `\_`).Replace(keyword)
	rows, err := r.Pool.Query(ctx, `SELECT station_id,node_id,name,longitude,latitude FROM stations WHERE name ILIKE $1 ESCAPE '\' OR station_id=$3 ORDER BY (station_id=$3) DESC,(lower(name) LIKE lower($2)) DESC,length(name),name,station_id LIMIT 20`, "%"+escaped+"%", escaped+"%", keyword)
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
func (r *PostgresRepository) Routes(ctx context.Context, id string) ([]Route, error) {
	rows, err := r.Pool.Query(ctx, `SELECT DISTINCT r.route_id,r.name FROM routes r JOIN route_stops s ON r.route_id=s.route_id WHERE s.station_id=$1 ORDER BY r.name,r.route_id`, id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Route{}
	for rows.Next() {
		var v Route
		if err := rows.Scan(&v.RouteID, &v.Name); err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

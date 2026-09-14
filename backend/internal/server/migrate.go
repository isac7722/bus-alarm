package server

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"
)

const catalogSQL = `
CREATE TABLE stations (station_id varchar(5) PRIMARY KEY,node_id varchar(9) NOT NULL,name varchar(128) NOT NULL,longitude double precision NOT NULL,latitude double precision NOT NULL);
CREATE INDEX ix_stations_node_id ON stations(node_id);
CREATE INDEX ix_stations_name ON stations(name);
CREATE TABLE routes (route_id varchar(9) PRIMARY KEY,name varchar(128) NOT NULL);
CREATE INDEX ix_routes_name ON routes(name);
CREATE TABLE route_stops (route_id varchar(9) REFERENCES routes(route_id) ON DELETE CASCADE,sequence integer,station_id varchar(5) NOT NULL REFERENCES stations(station_id) ON DELETE CASCADE,PRIMARY KEY(route_id,sequence),CONSTRAINT uq_route_stop UNIQUE(route_id,station_id,sequence));
CREATE INDEX ix_route_stops_station_id ON route_stops(station_id);
`

// Migrate shares the existing Alembic revision marker; no data rewrite or new baseline.
func Migrate(ctx context.Context, pool *pgxpool.Pool) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, "SELECT pg_advisory_xact_lock(728173642)"); err != nil {
		return err
	}
	if _, err = tx.Exec(ctx, "CREATE TABLE IF NOT EXISTS alembic_version (version_num varchar(32) NOT NULL CONSTRAINT alembic_version_pkc PRIMARY KEY)"); err != nil {
		return err
	}
	rows, err := tx.Query(ctx, "SELECT version_num FROM alembic_version")
	if err != nil {
		return err
	}
	versions := []string{}
	for rows.Next() {
		var v string
		if err := rows.Scan(&v); err != nil {
			rows.Close()
			return err
		}
		versions = append(versions, v)
	}
	rows.Close()
	if rows.Err() != nil {
		return rows.Err()
	}
	if len(versions) == 0 {
		if _, err = tx.Exec(ctx, catalogSQL); err != nil {
			return err
		}
		if _, err = tx.Exec(ctx, "INSERT INTO alembic_version(version_num) VALUES ('0001')"); err != nil {
			return err
		}
	} else if len(versions) != 1 || versions[0] != "0001" {
		return fmt.Errorf("unsupported database migration revision")
	}
	return tx.Commit(ctx)
}

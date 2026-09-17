package server

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"github.com/xuri/excelize/v2"
)

func testPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("set TEST_DATABASE_URL or run make test-backend-integration")
	}
	ctx := context.Background()
	admin, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	schema := fmt.Sprintf("go_test_%d", time.Now().UnixNano())
	if _, err := admin.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		admin.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, err := admin.Exec(ctx, "DROP SCHEMA "+schema+" CASCADE")
		admin.Close()
		if err != nil {
			t.Error(err)
		}
	})
	config, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	config.ConnConfig.RuntimeParams["search_path"] = schema
	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	return pool
}
func TestPostgresMigrationAndCatalog(t *testing.T) {
	ctx := context.Background()
	pool := testPool(t)
	if err := Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
	catalog, err := ReadCatalog("../../../seoul_bus_statiosn.xlsx")
	if err != nil {
		t.Fatal(err)
	}
	var counts struct{ Stations, Routes, RouteStops, Skipped int }
	b, err := os.ReadFile("testdata/python_catalog.json")
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]int
	_ = json.Unmarshal(b, &raw)
	counts.Stations = raw["stations"]
	counts.Routes = raw["routes"]
	counts.RouteStops = raw["route_stops"]
	counts.Skipped = raw["skipped"]
	if len(catalog.Stations) != counts.Stations || len(catalog.Routes) != counts.Routes || len(catalog.Stops) != counts.RouteStops || catalog.Skipped != counts.Skipped {
		t.Fatalf("catalog count mismatch: %d %d %d %d", len(catalog.Stations), len(catalog.Routes), len(catalog.Stops), catalog.Skipped)
	}
	if err := PersistCatalog(ctx, pool, catalog); err != nil {
		t.Fatal(err)
	}
	digests := func() map[string]string {
		out := map[string]string{}
		for _, table := range []string{"stations", "routes", "route_stops"} {
			var hash string
			sql := "SELECT md5(string_agg(t::text, E'\\n' ORDER BY t::text COLLATE \"C\")) FROM " + table + " t"
			if err := pool.QueryRow(ctx, sql).Scan(&hash); err != nil {
				t.Fatal(err)
			}
			out[table] = hash
		}
		return out
	}
	expected := map[string]string{}
	b, err = os.ReadFile("testdata/python_database.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, &expected); err != nil {
		t.Fatal(err)
	}
	before := digests()
	if !reflect.DeepEqual(before, expected) {
		t.Fatalf("full Python/Go data mismatch: got %v want %v", before, expected)
	}
	if err := Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(digests(), before) {
		t.Fatal("migration changed existing data")
	}
	if err := PersistCatalog(ctx, pool, catalog); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(digests(), before) {
		t.Fatal("import is not repeatable")
	}
	broken := catalog
	broken.Stops = append([]RouteStop{}, catalog.Stops...)
	broken.Stops = append(broken.Stops, RouteStop{"missing", 1, "99999"})
	if err := PersistCatalog(ctx, pool, broken); err == nil {
		t.Fatal("invalid foreign key accepted")
	}
	if !reflect.DeepEqual(digests(), before) {
		t.Fatal("failed import changed data")
	}
	if _, err := pool.Exec(ctx, "UPDATE alembic_version SET version_num='unknown'"); err != nil {
		t.Fatal(err)
	}
	if err := Migrate(ctx, pool); err == nil {
		t.Fatal("unknown revision accepted")
	}
	repo := &PostgresRepository{pool}
	station, err := repo.Get(ctx, "01136")
	if err != nil || station == nil || station.StationID != "01136" {
		t.Fatal(station, err)
	}
}
func TestExistingAlembicSchema(t *testing.T) {
	ctx := context.Background()
	pool := testPool(t)
	b, err := os.ReadFile("testdata/python_schema.sql")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, string(b)); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO stations VALUES ('22001','121000001','강남역',127.0276,37.4979)`); err != nil {
		t.Fatal(err)
	}
	if err := Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
	s, err := (&PostgresRepository{pool}).Get(ctx, "22001")
	if err != nil || s == nil {
		t.Fatal(s, err)
	}
}
func TestPostgresSearchOrdering(t *testing.T) {
	ctx := context.Background()
	pool := testPool(t)
	if err := Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
	for i, name := range []string{"역삼강남역", "강남역", "강남", "강남역사거리", "강_남", "강%남"} {
		if _, err := pool.Exec(ctx, "INSERT INTO stations VALUES ($1,'121000001',$2,127,37)", fmt.Sprintf("%05d", i), name); err != nil {
			t.Fatal(err)
		}
	}
	r := &PostgresRepository{pool}
	rows, err := r.Search(ctx, "강남")
	if err != nil {
		t.Fatal(err)
	}
	names := []string{}
	for _, s := range rows {
		names = append(names, s.Name)
	}
	if !reflect.DeepEqual(names, []string{"강남", "강남역", "강남역사거리", "역삼강남역"}) {
		t.Fatal(names)
	}
	for _, q := range []string{"%", "_"} {
		rows, err := r.Search(ctx, q)
		if err != nil || len(rows) != 1 {
			t.Fatal(q, rows, err)
		}
	}
	rows, err = r.Search(ctx, "00001")
	if err != nil || len(rows) != 1 || rows[0].Name != "강남역" {
		t.Fatal("station number search failed", rows, err)
	}
}
func TestRedisCompatibility(t *testing.T) {
	address := os.Getenv("TEST_REDIS_URL")
	if address == "" {
		t.Skip("set TEST_REDIS_URL or run make test-backend-integration")
	}
	options, err := redis.ParseURL(address)
	if err != nil {
		t.Fatal(err)
	}
	options.MaxRetries = -1
	c := redis.NewClient(options)
	defer c.Close()
	s := &RedisStore{c, 30, 2, 60}
	ctx := context.Background()
	if err := s.Ping(ctx); err != nil {
		t.Fatal(err)
	}
	id := fmt.Sprintf("test-%d", time.Now().UnixNano())
	key := "station:" + id + ":arrivals:live"
	defer c.Del(ctx, key, "rate:"+id)
	if b, err := s.Get(ctx, key); err != nil || b != nil {
		t.Fatal(string(b), err)
	}
	fixture, err := os.ReadFile("testdata/python_xml.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct{ Body json.RawMessage }
	_ = json.Unmarshal(fixture, &cases)
	b := []byte(cases[1].Body)
	if err := c.Set(ctx, key, b, 30*time.Second).Err(); err != nil {
		t.Fatal(err)
	}
	got, err := s.Get(ctx, key)
	if err != nil {
		t.Fatal(err)
	}
	var response ArrivalsResponse
	if err := decodeCached(got, &response); err != nil {
		t.Fatal(err)
	}
	if response.Arrivals[0].Predictions[0].RemainingSeconds == nil {
		t.Fatal("Python cached prediction lost")
	}
	if err := s.Set(ctx, key, b); err != nil {
		t.Fatal(err)
	}
	if ttl := c.TTL(ctx, key).Val(); ttl < 29*time.Second || ttl > 30*time.Second {
		t.Fatal(ttl)
	}
	for _, invalid := range []string{"bad json", "[]", "null"} {
		_ = c.Set(ctx, key, invalid, 0).Err()
		if _, err := s.Get(ctx, key); err == nil {
			t.Fatal("accepted corrupt cache")
		}
	}
	// Resume a window created by Python's INCR/EXPIRE sequence.
	_ = c.Set(ctx, "rate:"+id, 1, 42*time.Second).Err()
	r, err := s.Check(ctx, id)
	if err != nil || !r.Allowed || r.Remaining != 0 {
		t.Fatal(r, err)
	}
	r, err = s.Check(ctx, id)
	if err != nil || r.Allowed || r.RetryAfter < 41 || r.RetryAfter > 42 {
		t.Fatal(r, err)
	}
	_ = c.Del(ctx, "rate:"+id).Err()
	r, err = s.Check(ctx, id)
	if err != nil || !r.Allowed || r.RetryAfter != 60 {
		t.Fatal(r, err)
	}
	_ = c.Set(ctx, "rate:"+id, 2, 0).Err()
	r, err = s.Check(ctx, id)
	if err != nil || r.Allowed || r.RetryAfter != 60 {
		t.Fatal(r, err)
	}
	_ = c.Del(ctx, key, "rate:"+id).Err()
	_ = c.Close()
	if s.Ping(ctx) == nil {
		t.Fatal("closed Redis accepted")
	}
	if _, err := s.Get(ctx, key); err == nil {
		t.Fatal("read failure ignored")
	}
	if s.Set(ctx, key, b) == nil {
		t.Fatal("write failure ignored")
	}
	if _, err := s.Check(ctx, id); err == nil {
		t.Fatal("limiter failure ignored")
	}
}
func writeWorkbook(t *testing.T, rows [][]any) string {
	t.Helper()
	f := excelize.NewFile()
	defer f.Close()
	if err := f.SetSheetName("Sheet1", "Data"); err != nil {
		t.Fatal(err)
	}
	for i, row := range rows {
		cell, _ := excelize.CoordinatesToCellName(1, i+1)
		if err := f.SetSheetRow("Data", cell, &row); err != nil {
			t.Fatal(err)
		}
	}
	path := filepath.Join(t.TempDir(), "catalog.xlsx")
	if err := f.SaveAs(path); err != nil {
		t.Fatal(err)
	}
	return path
}
func TestCatalogValidation(t *testing.T) {
	headers := []any{}
	for _, v := range catalogHeaders {
		headers = append(headers, v)
	}
	row := []any{"100100341", "341", 1, "121000001", "01136", "하림각", 126.9617, 37.5981}
	path := writeWorkbook(t, [][]any{headers, row, {"200000001", "경기1", 2, "221000001", "01136", "경기정류소", 127, 37.5}})
	c, err := ReadCatalog(path)
	if err != nil || len(c.Stations) != 1 || c.Stations[0].StationID != "01136" || c.Skipped != 1 {
		t.Fatal(c, err)
	}
	for _, tc := range []struct {
		name    string
		col     int
		value   any
		message string
	}{{"ars", 4, "bad", "ARS_ID"}, {"node", 3, "123", "NODE_ID"}, {"sequence", 2, 0, "out-of-range"}, {"longitude", 6, 0, "out-of-range"}, {"numeric", 7, "no", "numeric"}, {"missing", 5, nil, "missing"}} {
		t.Run(tc.name, func(t *testing.T) {
			r := append([]any{}, row...)
			r[tc.col] = tc.value
			if _, err := ReadCatalog(writeWorkbook(t, [][]any{headers, r})); err == nil || !strings.Contains(err.Error(), tc.message) {
				t.Fatal(err)
			}
		})
	}
	if _, err := ReadCatalog(writeWorkbook(t, [][]any{{"bad"}, row})); err == nil {
		t.Fatal("bad headers accepted")
	}
	if _, err := ReadCatalog(writeWorkbook(t, [][]any{headers, row, row})); err == nil {
		t.Fatal("duplicate accepted")
	}
	conflict := append([]any{}, row...)
	conflict[2] = 2
	conflict[5] = "different"
	if _, err := ReadCatalog(writeWorkbook(t, [][]any{headers, row, conflict})); err == nil {
		t.Fatal("conflicting station accepted")
	}
}

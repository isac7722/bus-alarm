package server

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"testing"
)

type mapTestRepo struct {
	fakeRepo
	stations []Station
	calls    int
}

func (r *mapTestRepo) InBounds(_ context.Context, _ StationBounds) ([]Station, error) {
	r.calls++
	return r.stations, nil
}

func TestMapRejectsInvalidAndExcessiveBoundsBeforeQuery(t *testing.T) {
	repo := &mapTestRepo{}
	h := testHandler()
	h.Catalog = &RouteCatalog{Repository: repo}
	for _, query := range []string{"", "south=NaN&west=126&north=37&east=127", "south=38&north=37&west=127&east=127.01", "south=37&north=38&west=127&east=127.01", "south=37&north=37.01&west=-181&east=-180.99"} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest("GET", "/api/v2/stations/nearby?"+query, nil))
		if w.Code != 400 {
			t.Fatalf("accepted invalid bounds: %s, %d", query, w.Code)
		}
	}
	if repo.calls != 0 {
		t.Fatal("invalid bounds queried database")
	}
}
func TestMapKeepsPlatformsSeparateAndCapsResults(t *testing.T) {
	repo := &mapTestRepo{}
	for i := 0; i < 201; i++ {
		repo.stations = append(repo.stations, Station{StationID: fmt.Sprintf("%05d", i+1), NodeID: fmt.Sprintf("104%06d", i), Name: "같은 이름", Latitude: 37.535, Longitude: 127.094})
	}
	c := &RouteCatalog{Repository: repo}
	result, err := c.StationsInBounds(context.Background(), StationBounds{37.53, 127.09, 37.54, 127.10})
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Stations) != 200 || !result.Truncated || result.Stations[0].StationRef == result.Stations[1].StationRef {
		t.Fatal("platforms collapsed or cap missing")
	}
	repo.stations = nil
	h := testHandler()
	h.Catalog = c
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/api/v2/stations/nearby?south=37.53&west=127.09&north=37.54&east=127.10", nil))
	var empty StationMapResult
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &empty) != nil || empty.Stations == nil || len(empty.Stations) != 0 {
		t.Fatal(w.Body.String())
	}
}
func TestPostgresMapBoundsExcludeOutsideAndViaPoints(t *testing.T) {
	ctx := context.Background()
	pool := testPool(t)
	if err := Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
	_, err := pool.Exec(ctx, `INSERT INTO stations (station_id,node_id,name,longitude,latitude) VALUES
		('05267','104000069','강변역',127.094,37.535),
		('05268','104000070','강변역',127.095,37.536),
		('05269','104000071','차고지(경유)',127.094,37.535),
		('05270','104000072','영역 밖',128,38)`)
	if err != nil {
		t.Fatal(err)
	}
	r := &PostgresRepository{Pool: pool}
	rows, err := r.InBounds(ctx, StationBounds{37.53, 127.09, 37.54, 127.10})
	if err != nil || len(rows) != 2 {
		t.Fatalf("%+v %v", rows, err)
	}
}

package server

import (
	"encoding/json"
	"math"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/joho/godotenv"
)

type Config struct {
	AppEnv, AppName, Prefix, APIKey, APIBaseURL, DatabaseURL, RedisURL, CatalogPath string
	MockArrivals                                                                    bool
	RouteMapEnabled                                                                 bool
	CacheTTL, RateWindow, RateRequests                                              int
	HTTPTimeout                                                                     time.Duration
	CORSOrigins                                                                     []string
	APNsKeyPath, APNsKeyID, APNsTeamID, APNsBundleID                                string
	GyeonggiAPIKey, GyeonggiAPIBaseURL                                              string
}

func LoadConfig() (Config, error) {
	values, err := godotenv.Read(".env")
	if err != nil && !os.IsNotExist(err) {
		return Config{}, startupFailure("invalid .env file")
	}
	env := map[string]string{}
	for k, v := range values {
		env[strings.ToUpper(k)] = v
	}
	for _, kv := range os.Environ() {
		k, v, _ := strings.Cut(kv, "=")
		env[strings.ToUpper(k)] = v
	}
	return parseConfig(env)
}
func parseConfig(env map[string]string) (Config, error) {
	get := func(k, d string) string {
		if v, ok := env[k]; ok {
			return v
		}
		return d
	}
	c := Config{AppEnv: get("APP_ENV", "local"), AppName: get("APP_NAME", "BusWidget API"), Prefix: get("API_V1_PREFIX", "/api/v1"), APIKey: get("SEOUL_BUS_API_KEY", ""), APIBaseURL: strings.TrimRight(get("SEOUL_BUS_API_BASE_URL", "http://ws.bus.go.kr/api/rest/stationinfo"), "/"), DatabaseURL: get("DATABASE_URL", "postgresql+asyncpg://buswidget:buswidget@localhost:5432/buswidget"), RedisURL: get("REDIS_URL", "redis://localhost:6379/0"), CatalogPath: get("STATION_CATALOG_PATH", "../seoul_bus_statiosn.xlsx")}
	var err error
	c.RouteMapEnabled, err = strconv.ParseBool(get("ROUTE_MAP_ENABLED", "false"))
	if err != nil {
		return c, startupFailure("invalid ROUTE_MAP_ENABLED")
	}
	c.APNsKeyPath = get("APNS_KEY_PATH", "")
	c.GyeonggiAPIKey = strings.TrimSpace(get("GYEONGGI_BUS_API_KEY", ""))
	c.GyeonggiAPIBaseURL = strings.TrimRight(get("GYEONGGI_BUS_API_BASE_URL", "https://apis.data.go.kr/6410000"), "/")
	c.APNsKeyID = get("APNS_KEY_ID", "")
	c.APNsTeamID = get("APNS_TEAM_ID", "")
	c.APNsBundleID = get("APNS_BUNDLE_ID", "com.pangjoong.BusWidget")
	switch strings.ToLower(get("MOCK_ARRIVALS", "false")) {
	case "true", "1", "on", "yes", "y", "t":
		c.MockArrivals = true
	case "false", "0", "off", "no", "n", "f":
	default:
		return c, startupFailure("invalid MOCK_ARRIVALS")
	}
	for _, f := range []struct {
		k, d     string
		min, max int
		target   *int
	}{{"CACHE_TTL_SECONDS", "30", 1, 300, &c.CacheTTL}, {"RATE_LIMIT_REQUESTS", "60", 1, 0, &c.RateRequests}, {"RATE_LIMIT_WINDOW_SECONDS", "60", 1, 0, &c.RateWindow}} {
		value := strings.TrimSpace(get(f.k, f.d))
		n, err := strconv.Atoi(value)
		if err != nil {
			x, e := strconv.ParseFloat(value, 64)
			if e != nil || math.IsNaN(x) || math.IsInf(x, 0) || math.Trunc(x) != x || x > float64(math.MaxInt) {
				return c, startupFailure("invalid " + f.k)
			}
			n = int(x)
		}
		if n < f.min || f.max > 0 && n > f.max {
			return c, startupFailure("invalid " + f.k)
		}
		*f.target = n
	}
	seconds, err := strconv.ParseFloat(get("HTTP_TIMEOUT_SECONDS", "5"), 64)
	if err != nil || math.IsNaN(seconds) || seconds <= 0 || seconds > 30 {
		return c, startupFailure("invalid HTTP_TIMEOUT_SECONDS")
	}
	c.HTTPTimeout = time.Duration(seconds * float64(time.Second))
	if err := json.Unmarshal([]byte(get("CORS_ORIGINS", "[]")), &c.CORSOrigins); err != nil || c.CORSOrigins == nil {
		return c, startupFailure("invalid CORS_ORIGINS")
	}
	if c.Prefix != "" && (!strings.HasPrefix(c.Prefix, "/") || strings.HasSuffix(c.Prefix, "/")) {
		return c, startupFailure("invalid API_V1_PREFIX")
	}
	return c, nil
}
func databaseURL(s string) string {
	return strings.Replace(s, "postgresql+asyncpg://", "postgresql://", 1)
}

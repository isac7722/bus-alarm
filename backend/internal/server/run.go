package server

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
)

func NewLogger() *slog.Logger {
	return slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{ReplaceAttr: func(_ []string, a slog.Attr) slog.Attr {
		switch a.Key {
		case slog.TimeKey:
			a.Key = "timestamp"
			a.Value = slog.TimeValue(a.Value.Time().UTC())
		case slog.MessageKey:
			a.Key = "event"
		case slog.LevelKey:
			a.Value = slog.StringValue(stringsLower(a.Value.String()))
		}
		return a
	}}))
}
func stringsLower(s string) string {
	switch s {
	case "INFO":
		return "info"
	case "ERROR":
		return "error"
	case "WARN":
		return "warning"
	default:
		return "debug"
	}
}
func Run(args []string) error {
	command := "serve"
	if len(args) > 0 {
		command = args[0]
	}
	if len(args) > 1 {
		return fmt.Errorf("usage: buswidget [serve|migrate|import-stations|healthcheck]")
	}
	if command == "healthcheck" {
		client := http.Client{Timeout: 2 * time.Second}
		resp, err := client.Get("http://127.0.0.1:8000/health")
		if err != nil {
			return fmt.Errorf("health check failed")
		}
		defer resp.Body.Close()
		if resp.StatusCode >= 400 {
			return fmt.Errorf("health check failed")
		}
		return nil
	}
	if command != "serve" && command != "migrate" && command != "import-stations" {
		return fmt.Errorf("unknown command")
	}
	config, err := LoadConfig()
	if err != nil {
		return err
	}
	if command == "serve" {
		if err := validateAPNsConfig(config); err != nil {
			return err
		}
	}
	log := NewLogger()
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	poolConfig, err := pgxpool.ParseConfig(databaseURL(config.DatabaseURL))
	if err != nil {
		return startupFailure("invalid DATABASE_URL")
	}
	poolConfig.ConnConfig.ConnectTimeout = 5 * time.Second
	pool, err := pgxpool.NewWithConfig(ctx, poolConfig)
	if err != nil {
		return startupFailure("database initialization failed")
	}
	defer pool.Close()
	if command == "migrate" {
		return Migrate(ctx, pool)
	}
	if command == "import-stations" {
		catalog, err := ReadCatalog(config.CatalogPath)
		if err != nil {
			return err
		}
		if err := PersistCatalog(ctx, pool, catalog); err != nil {
			return err
		}
		log.Info("station_catalog_imported", "stations", len(catalog.Stations), "routes", len(catalog.Routes), "route_stops", len(catalog.Stops), "skipped_non_seoul_rows", catalog.Skipped)
		return nil
	}
	redisOptions, err := redis.ParseURL(config.RedisURL)
	if err != nil {
		return startupFailure("invalid REDIS_URL")
	}
	redisOptions.MaxRetries = -1
	redisClient := redis.NewClient(redisOptions)
	defer redisClient.Close()
	store := &RedisStore{redisClient, config.CacheTTL, config.RateRequests, config.RateWindow}
	repository := &PostgresRepository{pool}
	if err := repository.Ping(ctx); err != nil {
		return startupFailure("database connection failed")
	}
	if err := store.Ping(ctx); err != nil {
		return startupFailure("Redis connection failed")
	}
	// HTTPX applies the timeout to individual I/O phases, rather than the entire request.
	transport := newTransport(config.HTTPTimeout)
	defer transport.CloseIdleConnections()
	httpClient := &http.Client{Transport: transport, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}
	var client ArrivalClient = &SeoulClient{config, httpClient, time.Now, log}
	if config.MockArrivals {
		client = &MockClient{time.Now, log}
	} else if config.GyeonggiAPIKey != "" {
		client = &RegionalClient{Seoul: client.(*SeoulClient), Gyeonggi: &GyeonggiClient{Config: config, HTTP: httpClient, Cache: store, Now: time.Now, Log: log}, Repository: repository}
	}
	service := &Service{repository, store, client, log}
	handler := &Handler{Config: config, Service: service, Limiter: store, Log: log}
	if config.APNsKeyPath != "" {
		pusher, err := NewAPNsClient(config)
		if err != nil {
			return err
		}
		live := &LiveActivities{Redis: redisClient, Service: service, Source: client.(LiveArrivalClient), Pusher: pusher}
		handler.Live = live
		workerCtx, cancelWorker := context.WithCancel(ctx)
		workerDone := make(chan struct{})
		go func() { defer close(workerDone); live.Run(workerCtx) }()
		defer func() { cancelWorker(); <-workerDone; pusher.http.CloseIdleConnections() }()
		log.Info("live_activities_enabled")
	}
	httpServer := &http.Server{Addr: ":8000", Handler: handler, ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 5 * time.Second}
	log.Info("application_started", "app_env", config.AppEnv, "mock_arrivals", config.MockArrivals)
	done := make(chan error, 1)
	go func() { done <- httpServer.ListenAndServe() }()
	select {
	case err := <-done:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if err := httpServer.Shutdown(shutdown); err != nil {
			_ = httpServer.Close()
			return err
		}
	}
	log.Info("application_stopped")
	return nil
}

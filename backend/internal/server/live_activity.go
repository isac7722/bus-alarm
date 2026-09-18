package server

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"golang.org/x/sync/singleflight"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"
)

const livePrefix = "liveactivity:session:"
const liveLifetime = time.Hour

type LiveArrivalClient interface {
	FetchLive(context.Context, string, []Route) (LiveSnapshot, error)
}
type LiveActivities struct {
	Redis       *redis.Client
	Service     *Service
	Source      LiveArrivalClient
	Pusher      LivePusher
	Catalog     *RouteCatalog
	workersOnce sync.Once
	workers     chan struct{}
	snapshots   singleflight.Group
}
type liveTarget struct {
	RouteID  string             `json:"route_id"`
	Boarding *BoardingSelection `json:"boarding,omitempty"`
}

type liveRegistration struct {
	Routes      []liveTarget       `json:"routes,omitempty"`
	StationID   string             `json:"station_id"`
	RouteID     string             `json:"route_id"`
	PushToken   string             `json:"push_token"`
	Environment string             `json:"environment"`
	Boarding    *BoardingSelection `json:"boarding,omitempty"`
}

func hexValue(s string, min, max int) bool {
	if len(s) < min || len(s) > max || len(s)%2 != 0 {
		return false
	}
	_, err := hex.DecodeString(s)
	return err == nil
}
func liveKey(r *http.Request) (string, error) {
	bearer, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || !hexValue(bearer, 64, 64) {
		return "", appError("INVALID_SESSION", "대기 세션 인증 정보가 올바르지 않습니다.", 401)
	}
	digest := sha256.Sum256([]byte(bearer))
	return livePrefix + hex.EncodeToString(digest[:]), nil
}
func (h *Handler) serveLive(w http.ResponseWriter, r *http.Request) int {
	w.Header().Set("Cache-Control", "no-store")
	if r.URL.Path == h.Config.Prefix+"/live-activities/availability" {
		if r.Method != http.MethodGet {
			w.Header().Set("Allow", "GET")
			writeJSON(w, 405, map[string]string{"detail": "Method Not Allowed"})
			return 405
		}
		writeJSON(w, 200, map[string]bool{"available": h.Live != nil})
		return 200
	}
	if r.Method != http.MethodPost && r.Method != http.MethodDelete && r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET, POST, DELETE")
		writeJSON(w, 405, map[string]string{"detail": "Method Not Allowed"})
		return 405
	}
	if h.Live == nil {
		return h.writeError(w, appError("LIVE_ACTIVITIES_UNAVAILABLE", "실시간 현황 서비스를 준비 중입니다. 잠시 후 다시 시도해 주세요.", 503))
	}
	key, err := liveKey(r)
	if err != nil {
		return h.writeError(w, err)
	}
	if r.Method == http.MethodGet {
		h.Live.processSession(r.Context(), key, map[string]LiveSnapshot{}, false)
		raw, e := h.Live.Redis.Get(r.Context(), key).Bytes()
		if errors.Is(e, redis.Nil) {
			return h.writeError(w, appError("LIVE_ACTIVITY_ENDED", "종료된 대기입니다.", 409))
		}
		var current LiveSession
		if e != nil || json.Unmarshal(raw, &current) != nil {
			return h.writeError(w, cacheError())
		}
		writeJSON(w, 200, map[string]any{"expires_at": current.ExpiresAt, "content": current.Content})
		return 200
	}
	var session LiveSession
	if r.Method == http.MethodDelete {
		err = h.Live.mutate(r.Context(), key, func(current *LiveSession) error {
			current.Ended = true
			current.Content = LiveContent{Status: "cancelled", UpdatedAt: float64(time.Now().Unix())}
			current.NextPushAt = 0
			current.PushRetry = 0
			current.Content.Revision = time.Now().UnixMilli()
			if current.ExpiresAt == 0 {
				current.ExpiresAt = time.Now().Add(liveLifetime).Unix()
			}
			return nil
		}, &session)
	} else {
		var registration liveRegistration
		decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&registration) != nil || decoder.Decode(new(any)) != io.EOF || !hexValue(registration.PushToken, 64, 512) || (registration.Environment != "sandbox" && registration.Environment != "production") {
			return h.writeError(w, invalid())
		}
		if registration.Routes != nil {
			return h.serveLiveGroup(w, r, key, registration)
		}
		if !validLiveRouteID(registration.RouteID) {
			return h.writeError(w, invalid())
		}

		var routes []Route
		if r.URL.Path == "/api/v2/live-activities" {
			if h.Catalog == nil || registration.Boarding == nil {
				return h.writeError(w, invalid())
			}
			validated, e := h.Catalog.Validate(r.Context(), SelectionRequest{registration.StationID, []BoardingSelection{*registration.Boarding}})
			if e != nil {
				return h.writeError(w, e)
			}
			if registration.RouteID != validated.Selections[0].RouteRef {
				return h.writeError(w, invalid())
			}
			registration.Boarding = &validated.Selections[0]
		} else {
			if !stationIDValid(registration.StationID) || registration.Boarding != nil {
				return h.writeError(w, invalid())
			}
			if _, err = h.Service.requireStation(r.Context(), registration.StationID); err != nil {
				return h.writeError(w, err)
			}
			var routeErr error
			routes, routeErr = h.Service.StationRoutes(r.Context(), registration.StationID)
			if routeErr != nil {
				return h.writeError(w, routeErr)
			}
			found := false
			for _, route := range routes {
				if route.RouteID == registration.RouteID {
					found = true
				}
			}
			if !found {
				return h.writeError(w, appError("ROUTE_NOT_FOUND", "정류소에서 요청한 노선을 찾을 수 없습니다.", 404))
			}

		}
		var initial LiveSnapshot
		if exists, redisErr := h.Live.Redis.Exists(r.Context(), key).Result(); redisErr != nil {
			return h.writeError(w, cacheError())
		} else if exists == 0 {
			fetchCtx, cancel := context.WithTimeout(r.Context(), 6*time.Second)
			if registration.Boarding != nil {
				initial, err = h.Catalog.BoardingLive(fetchCtx, *registration.Boarding)
			} else {
				initial, err = h.Live.Source.FetchLive(fetchCtx, registration.StationID, routes)
			}
			cancel()
			if err != nil {
				return h.writeError(w, upstreamError("버스 도착 정보를 확인하지 못했습니다. 다시 시도해 주세요."))
			}
		}
		err = h.Live.mutate(r.Context(), key, func(current *LiveSession) error {
			now := time.Now()
			if current.Ended || current.ExpiresAt != 0 && current.ExpiresAt <= now.Unix() {
				return appError("LIVE_ACTIVITY_ENDED", "종료된 대기입니다. 새로 시작해 주세요.", 409)
			}
			if current.ExpiresAt != 0 && (current.StationID != registration.StationID || current.RouteID != registration.RouteID || current.Environment != registration.Environment || !sameBoarding(current.Boarding, registration.Boarding)) {
				return invalid()
			}
			if current.ExpiresAt == 0 {
				current.StationID = registration.StationID
				current.RouteID = registration.RouteID
				current.Boarding = registration.Boarding
				current.Environment = registration.Environment
				current.ExpiresAt = now.Add(liveLifetime).Unix()
				current.Content = LiveContent{Status: "waiting", UpdatedAt: float64(now.Unix())}
				current.advance(initial, now)
				if current.Content.ArrivalAt == nil || current.Ended {
					return appError("LIVE_NO_PREDICTION", "운행 중인 버스의 도착 정보가 없어 대기를 시작할 수 없습니다.", 409)
				}
			}
			if current.Content.Revision == 0 {
				current.Content.Revision = time.Now().UnixMilli()
			}
			current.PushToken = strings.ToLower(registration.PushToken)
			return nil
		}, &session)
	}
	if err != nil {
		return h.writeError(w, err)
	}
	writeJSON(w, 200, map[string]any{"expires_at": session.ExpiresAt, "content": session.Content})
	return 200
}

// WATCH preserves worker progress when a push token rotates and prevents a late
// registration from resurrecting a cancelled activity. Tombstones expire too.
func (l *LiveActivities) mutate(ctx context.Context, key string, change func(*LiveSession) error, result *LiveSession) error {
	for attempt := 0; attempt < 5; attempt++ {
		err := l.Redis.Watch(ctx, func(tx *redis.Tx) error {
			var current LiveSession
			data, err := tx.Get(ctx, key).Bytes()
			if err != nil && !errors.Is(err, redis.Nil) {
				return cacheError()
			}
			if len(data) > 0 && json.Unmarshal(data, &current) != nil {
				return cacheError()
			}
			if err := change(&current); err != nil {
				return err
			}
			encoded, _ := json.Marshal(current)
			ttl := time.Until(time.Unix(current.ExpiresAt, 0).Add(5 * time.Minute))
			if ttl <= 0 {
				ttl = time.Minute
			}
			_, err = tx.TxPipelined(ctx, func(p redis.Pipeliner) error { p.Set(ctx, key, encoded, ttl); return nil })
			if err == nil {
				*result = current
			}
			return err
		}, key)
		if errors.Is(err, redis.TxFailedErr) {
			continue
		}
		if err != nil {
			var app *AppError
			if errors.As(err, &app) {
				return app
			}
			return cacheError()
		}
		return nil
	}
	return cacheError()
}

var liveCompareSet = redis.NewScript(`
if redis.call('GET', KEYS[1]) == ARGV[1] then
 return redis.call('SET', KEYS[1], ARGV[2], 'KEEPTTL')
end
return false`)
var liveUnlock = redis.NewScript(`if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) end return 0`)

func (l *LiveActivities) Run(ctx context.Context) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		l.tick(ctx)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
func (l *LiveActivities) tick(ctx context.Context) {
	// Never sleep through a retry or let a slow device block other waits.
	l.workersOnce.Do(func() { l.workers = make(chan struct{}, 32) })
	iterator := l.Redis.Scan(ctx, 0, livePrefix+"*", 100).Iterator()
	for iterator.Next(ctx) {
		if strings.HasSuffix(iterator.Val(), ":lock") {
			continue
		}
		if ctx.Err() != nil {
			return
		}
		key := iterator.Val()
		select {
		case l.workers <- struct{}{}:
			go func() { defer func() { <-l.workers }(); l.process(ctx, key, map[string]LiveSnapshot{}) }()
		default:
			// Busy sessions are revisited on the next one-second scheduler tick.
		}
	}
	if iterator.Err() != nil && ctx.Err() == nil {
		l.Service.Log.Warn("live_activity_scan_failed")
	}
}
func (l *LiveActivities) process(ctx context.Context, key string, snapshots map[string]LiveSnapshot) {
	l.processSession(ctx, key, snapshots, true)
}
func (l *LiveActivities) processSession(ctx context.Context, key string, snapshots map[string]LiveSnapshot, push bool) {
	lock := key + ":lock"
	owner := make([]byte, 16)
	if _, err := rand.Read(owner); err != nil {
		return
	}
	locked, err := l.Redis.SetNX(ctx, lock, owner, 30*time.Second).Result()
	if err != nil || !locked {
		return
	}
	defer func() {
		unlockCtx, stop := context.WithTimeout(context.WithoutCancel(ctx), time.Second)
		defer stop()
		_, _ = liveUnlock.Run(unlockCtx, l.Redis, []string{lock}, owner).Result()
	}()
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	raw, err := l.Redis.Get(ctx, key).Bytes()
	if err != nil {
		return
	}
	var session LiveSession
	if json.Unmarshal(raw, &session) != nil || session.PushToken == "" || (push && session.NextPushAt > time.Now().Unix()) {
		return
	}
	now := time.Now()
	if !session.Ended && ((!push || session.PushRetry == 0) && session.NextRefreshAt <= now.Unix() || now.Unix() >= session.ExpiresAt) {
		revision := session.Content.Revision
		if len(session.Routes) > 0 {
			for i := range session.Routes {
				child := &session.Routes[i]
				if !child.Ended {
					child.advance(l.snapshot(ctx, *child, snapshots), now)
				}
			}
			session.aggregate(time.Now())
		} else {
			session.advance(l.snapshot(ctx, session, snapshots), now)
		}
		session.Content.Revision = max(revision+1, time.Now().UnixMilli())
		session.NextRefreshAt = time.Now().Add(5 * time.Second).Unix()
	}
	if push {
		// A cancellation/token rotation while fetching takes precedence over this work.
		latest, e := l.Redis.Get(ctx, key).Result()
		if e != nil || latest != string(raw) {
			return
		}
		// A display-boundary push may precede the next upstream refresh. Give it
		// a new revision so ActivityKit redraws even when the ETA is unchanged.
		session.Content.Revision = max(session.Content.Revision+1, time.Now().UnixMilli())
		invalid, pushErr := l.Pusher.Push(ctx, session)
		session.schedulePush(time.Now(), pushErr)
		if pushErr != nil {
			l.Service.Log.Warn("live_activity_push_failed", "error", pushErr.Error())
		} else if session.Ended || invalid {
			session.PushToken = ""
			session.Ended = true
		}
	}
	encoded, _ := json.Marshal(session)
	if _, err := liveCompareSet.Run(ctx, l.Redis, []string{key}, raw, encoded).Result(); err != nil && ctx.Err() == nil {
		l.Service.Log.Warn("live_activity_save_failed")
	}
}

func validateAPNsConfig(c Config) error {
	if c.APNsKeyPath == "" && c.APNsKeyID == "" && c.APNsTeamID == "" {
		return nil
	}
	if c.APNsKeyPath == "" || c.APNsKeyID == "" || c.APNsTeamID == "" || c.APNsBundleID == "" {
		return startupFailure("set APNS_KEY_PATH, APNS_KEY_ID, APNS_TEAM_ID and APNS_BUNDLE_ID together; Docker deployments need docker-compose.apns.yml")
	}
	return nil
}

func sameBoarding(a, b *BoardingSelection) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return a.BoardingID == b.BoardingID && a.RouteRevision == b.RouteRevision
}

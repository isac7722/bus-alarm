package server

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"buswidget/app/content"
)

type Handler struct {
	Config  Config
	Service *Service
	Limiter Limiter
	Log     *slog.Logger
	Live    *LiveActivities
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	started := time.Now()
	status := 200
	defer func() {
		if recover() != nil {
			status = 500
			h.writeError(w, fmt.Errorf("unhandled panic"))
		}
		h.Log.Info("request_completed", "method", r.Method, "path", r.URL.Path, "status_code", status, "client", r.RemoteAddr, "latency_ms", float64(time.Since(started).Microseconds()/10)/100)
	}()
	if strings.HasPrefix(r.URL.Path, h.Config.Prefix) && h.Limiter != nil {
		identity, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil {
			identity = r.RemoteAddr
		}
		if identity == "" {
			identity = "unknown"
		}
		// Uvicorn trusts proxy headers only from its default trusted peer (127.0.0.1).
		if identity == "127.0.0.1" {
			forwarded := strings.Split(r.Header.Get("X-Forwarded-For"), ",")
			for i := len(forwarded) - 1; i >= 0; i-- {
				ip := strings.TrimSpace(forwarded[i])
				if ip != "" && ip != "127.0.0.1" {
					identity = ip
					break
				}
			}
		}
		result, err := h.Limiter.Check(r.Context(), identity)
		if err != nil {
			status = h.writeError(w, err)
			return
		}
		if !result.Allowed {
			w.Header().Set("Retry-After", strconv.Itoa(result.RetryAfter))
			status = h.writeError(w, appError("RATE_LIMIT_EXCEEDED", "요청이 너무 많습니다. 잠시 후 다시 시도해 주세요.", 429))
			return
		}
	}
	if h.cors(w, r) {
		return
	}
	path := r.URL.Path
	if path == h.Config.Prefix+"/live-activities" || path == h.Config.Prefix+"/live-activities/availability" {
		status = h.serveLive(w, r)
		return
	}
	kind, id := h.route(path)
	if kind == "" && path != "/" {
		trimmed := strings.TrimRight(path, "/")
		if k, _ := h.route(trimmed); k != "" {
			u := *r.URL
			u.Path = trimmed
			u.RawPath = ""
			u.Scheme = "http"
			if r.TLS != nil {
				u.Scheme = "https"
			}
			peer, _, _ := net.SplitHostPort(r.RemoteAddr)
			if peer == "127.0.0.1" && r.Header.Get("X-Forwarded-Proto") != "" {
				u.Scheme = r.Header.Get("X-Forwarded-Proto")
			}
			u.Host = r.Host
			w.Header().Set("Location", u.String())
			w.Header().Set("Content-Length", "0")
			status = 307
			w.WriteHeader(status)
			return
		}
	}
	if kind == "" {
		status = 404
		writeJSON(w, status, map[string]string{"detail": "Not Found"})
		return
	}
	if r.Method != "GET" {
		status = 405
		w.Header().Set("Allow", "GET")
		writeJSON(w, status, map[string]string{"detail": "Method Not Allowed"})
		return
	}
	if kind == "privacy" {
		body, err := content.RenderPrivacy()
		if err != nil {
			status = h.writeError(w, err)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Length", strconv.Itoa(len(body)))
		_, _ = w.Write([]byte(body))
		return
	}
	var result any
	var err error
	switch kind {
	case "health":
		err = h.Service.Repository.Ping(r.Context())
		if err == nil {
			err = h.Service.Cache.Ping(r.Context())
		}
		result = map[string]string{"status": "ok"}
	case "search":
		q := lastQuery(r, "q")
		if utf8.RuneCountInString(q) > 60 {
			err = invalid()
		} else {
			result, err = h.Service.Search(r.Context(), q)
		}
	case "detail", "arrivals":
		if !stationIDValid(id) {
			err = invalid()
		} else if kind == "detail" {
			result, err = h.Service.Detail(r.Context(), id)
		} else {
			result, err = h.Service.Arrivals(r.Context(), id, lastQuery(r, "route_ids"))
		}
	}
	if err != nil {
		status = h.writeError(w, err)
		return
	}
	writeJSON(w, 200, result)
}
func lastQuery(r *http.Request, key string) string {
	v := r.URL.Query()[key]
	if len(v) == 0 {
		return ""
	}
	return v[len(v)-1]
}
func stationIDValid(id string) bool {
	if node, ok := strings.CutPrefix(id, "gg:"); ok {
		return gbisNodeValid(node)
	}
	if utf8.RuneCountInString(id) != 5 {
		return false
	}
	for _, r := range id {
		if !unicode.Is(unicode.Nd, r) {
			return false
		}
	}
	return true
}
func (h *Handler) route(path string) (string, string) {
	if path == "/health" {
		return "health", ""
	}
	if path == "/privacy" {
		return "privacy", ""
	}
	base := h.Config.Prefix + "/stations/"
	if !strings.HasPrefix(path, base) {
		return "", ""
	}
	s := strings.TrimPrefix(path, base)
	if s == "search" {
		return "search", ""
	}
	if s == "" {
		return "", ""
	}
	if !strings.Contains(s, "/") {
		return "detail", s
	}
	id, tail, _ := strings.Cut(s, "/")
	if id != "" && tail == "arrivals" {
		return "arrivals", id
	}
	return "", ""
}
func writeJSON(w http.ResponseWriter, status int, v any) {
	b, err := json.Marshal(v)
	if err != nil {
		status = 500
		b = []byte(`{"error":{"code":"INTERNAL_SERVER_ERROR","message":"서버 오류가 발생했습니다."}}`)
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", strconv.Itoa(len(b)))
	w.WriteHeader(status)
	_, _ = w.Write(b)
}
func (h *Handler) writeError(w http.ResponseWriter, err error) int {
	var e *AppError
	if !errors.As(err, &e) {
		h.Log.Error("unhandled_error", "error_type", fmt.Sprintf("%T", err))
		e = &AppError{"INTERNAL_SERVER_ERROR", "서버 오류가 발생했습니다.", 500}
	}
	writeJSON(w, e.Status, map[string]any{"error": e})
	return e.Status
}
func (h *Handler) cors(w http.ResponseWriter, r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" || len(h.Config.CORSOrigins) == 0 {
		return false
	}
	all, allowed := false, false
	for _, v := range h.Config.CORSOrigins {
		if v == "*" {
			all = true
			allowed = true
		}
		if v == origin {
			allowed = true
		}
	}
	if r.Method == "OPTIONS" && r.Header.Get("Access-Control-Request-Method") != "" {
		if all {
			w.Header().Set("Access-Control-Allow-Origin", "*")
		} else {
			w.Header().Set("Vary", "Origin")
			if allowed {
				w.Header().Set("Access-Control-Allow-Origin", origin)
			}
		}
		methods := []string{"GET"}
		if r.URL.Path == h.Config.Prefix+"/live-activities" {
			methods = []string{"POST", "DELETE"}
		}
		w.Header().Set("Access-Control-Allow-Methods", strings.Join(methods, ", "))
		w.Header().Set("Access-Control-Max-Age", "600")
		if headers := r.Header.Get("Access-Control-Request-Headers"); headers != "" {
			w.Header().Set("Access-Control-Allow-Headers", headers)
		}
		failures := []string{}
		if !allowed {
			failures = append(failures, "origin")
		}
		methodAllowed := false
		for _, method := range methods {
			if r.Header.Get("Access-Control-Request-Method") == method {
				methodAllowed = true
			}
		}
		if !methodAllowed {
			failures = append(failures, "method")
		}
		status, body := 200, "OK"
		if len(failures) > 0 {
			status = 400
			body = "Disallowed CORS " + strings.Join(failures, ", ")
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Content-Length", strconv.Itoa(len(body)))
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
		return true
	}
	if all {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		if r.Header.Get("Cookie") != "" {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Vary", "Origin")
		}
	} else if allowed {
		w.Header().Set("Access-Control-Allow-Origin", origin)
		w.Header().Set("Vary", "Origin")
	}
	return false
}

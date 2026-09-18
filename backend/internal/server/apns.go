package server

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"os"
	"sync"
	"time"
)

type LivePusher interface {
	Push(context.Context, LiveSession) (bool, error)
}

type APNsClient struct {
	key                     *ecdsa.PrivateKey
	keyID, teamID, bundleID string
	http                    *http.Client
	mu                      sync.Mutex
	jwt                     string
	issued                  time.Time
}

func NewAPNsClient(c Config) (*APNsClient, error) {
	data, err := os.ReadFile(c.APNsKeyPath)
	if err != nil {
		return nil, startupFailure("cannot read APNS_KEY_PATH; check the APNs secret mount and file permissions")
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, startupFailure("APNS_KEY_PATH must contain a PKCS8 private key")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, startupFailure("invalid APNs private key")
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok || key.Curve != elliptic.P256() {
		return nil, startupFailure("APNs requires an ES256 private key")
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.ForceAttemptHTTP2 = true
	return &APNsClient{key: key, keyID: c.APNsKeyID, teamID: c.APNsTeamID, bundleID: c.APNsBundleID,
		http: &http.Client{Transport: transport, Timeout: 10 * time.Second, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}}, nil
}
func (a *APNsClient) token(now time.Time) (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.jwt != "" && now.Sub(a.issued) < 50*time.Minute {
		return a.jwt, nil
	}
	encode := func(value any) string { b, _ := json.Marshal(value); return base64.RawURLEncoding.EncodeToString(b) }
	unsigned := encode(map[string]string{"alg": "ES256", "kid": a.keyID}) + "." + encode(map[string]any{"iss": a.teamID, "iat": now.Unix()})
	digest := sha256.Sum256([]byte(unsigned))
	r, s, err := ecdsa.Sign(rand.Reader, a.key, digest[:])
	if err != nil {
		return "", fmt.Errorf("APNs signing failed")
	}
	signature := make([]byte, 64)
	r.FillBytes(signature[:32])
	s.FillBytes(signature[32:])
	a.jwt = unsigned + "." + base64.RawURLEncoding.EncodeToString(signature)
	a.issued = now
	return a.jwt, nil
}
func livePayload(session LiveSession, now time.Time) []byte {
	// The first future ETA schedules the next time-dependent presentation change.
	// Source age never hides a still-running countdown.
	staleAt := session.ExpiresAt
	contents := []LiveContent{session.Content}
	for _, route := range session.Content.Routes {
		contents = append(contents, route.Content)
	}
	for _, c := range contents {
		if c.Status == "waiting" && c.ArrivalAt != nil && *c.ArrivalAt > float64(now.Unix()) && (staleAt == 0 || int64(*c.ArrivalAt) < staleAt) {
			staleAt = int64(*c.ArrivalAt)
		}
	}
	aps := map[string]any{"timestamp": now.Unix(), "event": "update", "content-state": session.Content}
	if staleAt > now.Unix() {
		aps["stale-date"] = staleAt
	}

	if session.Ended {
		aps["event"] = "end"
		aps["dismissal-date"] = now.Add(time.Minute).Unix()
	}
	body, _ := json.Marshal(map[string]any{"aps": aps})
	return body
}

// The bool means the activity token is permanently invalid and can be deleted.
func (a *APNsClient) Push(ctx context.Context, session LiveSession) (bool, error) {
	now := time.Now()
	token, err := a.token(now)
	if err != nil {
		return false, err
	}
	host := "https://api.push.apple.com"
	if session.Environment == "sandbox" {
		host = "https://api.sandbox.push.apple.com"
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, host+"/3/device/"+session.PushToken, bytes.NewReader(livePayload(session, now)))
	if err != nil {
		return false, fmt.Errorf("invalid APNs request")
	}
	req.Header.Set("authorization", "bearer "+token)
	req.Header.Set("apns-topic", a.bundleID+".push-type.liveactivity")
	req.Header.Set("apns-push-type", "liveactivity")
	req.Header.Set("apns-priority", "5")
	if session.Ended {
		req.Header.Set("apns-priority", "10")
	}
	req.Header.Set("apns-expiration", fmt.Sprint(now.Add(90*time.Second).Unix()))
	req.Header.Set("content-type", "application/json")
	response, err := a.http.Do(req)
	if err != nil {
		return false, fmt.Errorf("APNs transport failed")
	} // No token-bearing URL in logs.
	defer response.Body.Close()
	var detail struct {
		Reason string `json:"reason"`
	}
	_ = json.NewDecoder(io.LimitReader(response.Body, 4096)).Decode(&detail)
	if response.StatusCode == 200 {
		return false, nil
	}
	if response.StatusCode == 410 || response.StatusCode == 400 && (detail.Reason == "BadDeviceToken" || detail.Reason == "DeviceTokenNotForTopic") {
		return true, nil
	}
	return false, &pushResponseError{Status: response.StatusCode, Reason: detail.Reason}
}

// Transport errors use short retries. APNs rejections require status-specific recovery.
type pushResponseError struct {
	Status int
	Reason string
}

func (e *pushResponseError) Error() string {
	return fmt.Sprintf("APNs rejected push (HTTP %d, %s)", e.Status, e.Reason)
}
func (s *LiveSession) schedulePush(now time.Time, err error) {
	s.NextPushAt = now.Add(10 * time.Second).Unix()
	if err == nil {
		s.PushRetry = 0
		return
	}
	if rejection, ok := err.(*pushResponseError); ok {
		s.PushRetry = 0
		switch {
		case rejection.Status >= 500:
			s.NextPushAt = now.Add(15 * time.Minute).Unix()
		case rejection.Status == 429:
			s.NextPushAt = now.Add(time.Minute).Unix()
		default:
			s.NextPushAt = now.Add(15 * time.Minute).Unix()
		}
		return
	}
	delays := []time.Duration{time.Second, 3 * time.Second, 5 * time.Second}
	if s.PushRetry < len(delays) {
		s.NextPushAt = now.Add(delays[s.PushRetry]).Unix()
		s.PushRetry++
	} else {
		s.PushRetry = 0
	}
}

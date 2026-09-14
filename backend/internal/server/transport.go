package server

import (
	"context"
	"net"
	"net/http"
	"time"
)

// Reset deadlines for each read/write to match HTTPX's per-operation timeout.
type deadlineConn struct {
	net.Conn
	timeout time.Duration
}

func (c *deadlineConn) Read(b []byte) (int, error) {
	if err := c.SetReadDeadline(time.Now().Add(c.timeout)); err != nil {
		return 0, err
	}
	return c.Conn.Read(b)
}
func (c *deadlineConn) Write(b []byte) (int, error) {
	if err := c.SetWriteDeadline(time.Now().Add(c.timeout)); err != nil {
		return 0, err
	}
	return c.Conn.Write(b)
}
func newTransport(timeout time.Duration) *http.Transport {
	t := http.DefaultTransport.(*http.Transport).Clone()
	t.ForceAttemptHTTP2 = false
	t.TLSHandshakeTimeout = timeout
	t.ResponseHeaderTimeout = timeout
	t.MaxIdleConns = 20
	t.IdleConnTimeout = 5 * time.Second
	t.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		conn, err := (&net.Dialer{Timeout: timeout, KeepAlive: 30 * time.Second}).DialContext(ctx, network, address)
		if err != nil {
			return nil, err
		}
		return &deadlineConn{conn, timeout}, nil
	}
	return t
}

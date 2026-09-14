package server

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/redis/go-redis/v9"
)

type Cache interface {
	Ping(context.Context) error
	Get(context.Context, string) ([]byte, error)
	Set(context.Context, string, []byte) error
}
type LimitResult struct {
	Allowed               bool
	Remaining, RetryAfter int
}
type Limiter interface {
	Check(context.Context, string) (LimitResult, error)
}
type RedisStore struct {
	Client                *redis.Client
	TTL, Requests, Window int
}

func (s *RedisStore) Ping(ctx context.Context) error {
	if s.Client.Ping(ctx).Err() != nil {
		return cacheError()
	}
	return nil
}
func (s *RedisStore) Get(ctx context.Context, key string) ([]byte, error) {
	b, err := s.Client.Get(ctx, key).Bytes()
	if errors.Is(err, redis.Nil) {
		return nil, nil
	}
	if err != nil {
		return nil, cacheError()
	}
	var value map[string]json.RawMessage
	if json.Unmarshal(b, &value) != nil || value == nil {
		return nil, cacheError()
	}
	return b, nil
}
func (s *RedisStore) Set(ctx context.Context, key string, b []byte) error {
	if s.Client.Set(ctx, key, b, time.Duration(s.TTL)*time.Second).Err() != nil {
		return cacheError()
	}
	return nil
}
func (s *RedisStore) Check(ctx context.Context, identity string) (LimitResult, error) {
	key := "rate:" + identity
	pipe := s.Client.TxPipeline()
	countCmd := pipe.Incr(ctx, key)
	ttlCmd := pipe.TTL(ctx, key)
	if _, err := pipe.Exec(ctx); err != nil {
		return LimitResult{}, cacheError()
	}
	count := int(countCmd.Val())
	ttl := int(ttlCmd.Val() / time.Second)
	if count == 1 || ttlCmd.Val() < 0 {
		if s.Client.Expire(ctx, key, time.Duration(s.Window)*time.Second).Err() != nil {
			return LimitResult{}, cacheError()
		}
		ttl = s.Window
	}
	return LimitResult{count <= s.Requests, max(s.Requests-count, 0), max(ttl, 1)}, nil
}

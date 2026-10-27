// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"database/sql"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"time"

	"google.golang.org/grpc/metadata"
)

// priceHistoryEnabled is set once at startup by startPriceHistory, before the
// gRPC server starts, so GetProduct can read it without synchronisation.
var priceHistoryEnabled bool

// startPriceHistory records every product's price every
// PRICE_HISTORY_SAMPLE_INTERVAL (a Go duration such as "3s"; unset disables it)
// so GetProduct can report, when an order is placed, how often a product's
// price has changed. The history table lives in its own schema, created on
// first use. The goroutine stops when ctx is cancelled.
func startPriceHistory(ctx context.Context) {
	v := os.Getenv("PRICE_HISTORY_SAMPLE_INTERVAL")
	if v == "" {
		return
	}
	interval, err := time.ParseDuration(v)
	if err != nil || interval <= 0 {
		logger.Error("Invalid PRICE_HISTORY_SAMPLE_INTERVAL, price history disabled", slog.String("value", v))
		return
	}
	if _, err := db.ExecContext(ctx, `
		CREATE SCHEMA IF NOT EXISTS pricing;
		CREATE TABLE IF NOT EXISTS pricing.price_history (
			product_id  TEXT        NOT NULL,
			price_units BIGINT      NOT NULL,
			price_nanos INT         NOT NULL,
			sampled_at  TIMESTAMPTZ NOT NULL DEFAULT now()
		)`); err != nil {
		logger.Error("Price history table unavailable, price history disabled", slog.Any("error", err))
		return
	}
	priceHistoryEnabled = true
	logger.Info("Price history enabled", slog.Duration("sample_interval", interval))

	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
			if _, err := db.ExecContext(ctx, `
				INSERT INTO pricing.price_history (product_id, price_units, price_nanos)
				SELECT id, price_units, price_nanos FROM catalog.products`); err != nil {
				logger.Warn("Price history sample failed", slog.Any("error", err))
			}
		}
	}()
}

// orderTimeLookup reports whether a GetProduct call comes from the order
// service. The price check is shown when an order is placed, not while the
// customer browses, so storefront lookups skip it. In this demo the order
// service (checkout) is the catalogue's only Go gRPC client; the storefront
// calls it through grpc-js.
func orderTimeLookup(ctx context.Context) bool {
	md, ok := metadata.FromIncomingContext(ctx)
	if !ok {
		return false
	}
	for _, ua := range md.Get("user-agent") {
		if strings.Contains(ua, "grpc-go/") {
			return true
		}
	}
	return false
}

// priceChangeCount returns how many times a product's price differed from the
// sample before it.
//
// JIT is turned off for this query: once the history is a few thousand rows the
// planner JIT-compiles it on every call, and each compile keeps memory in the
// database backend until the connection closes. On a small database container
// that ends in an OOM kill within minutes, not in a slow lookup.
func priceChangeCount(ctx context.Context, productID string) (int64, error) {
	tx, err := db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return 0, fmt.Errorf("priceChangeCount: begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.ExecContext(ctx, `SET LOCAL jit = off`); err != nil {
		return 0, fmt.Errorf("priceChangeCount: %w", err)
	}

	var n int64
	err = tx.QueryRowContext(ctx, `
		SELECT count(*)
		FROM pricing.price_history h
		WHERE h.product_id = $1
		  AND h.price_units <> (
		      SELECT p.price_units
		      FROM pricing.price_history p
		      WHERE p.product_id = h.product_id
		        AND p.sampled_at < h.sampled_at
		      ORDER BY p.sampled_at DESC
		      LIMIT 1)
	`, productID).Scan(&n)
	if err != nil {
		return 0, fmt.Errorf("priceChangeCount: %w", err)
	}
	return n, nil
}

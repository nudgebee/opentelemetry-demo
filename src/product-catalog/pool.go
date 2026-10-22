// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"database/sql"
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"time"
)

// configurePool applies DB_MAX_OPEN_CONNS to the connection pool. Unset or 0
// keeps the database/sql default, which is no limit.
func configurePool(db *sql.DB) error {
	v := os.Getenv("DB_MAX_OPEN_CONNS")
	if v == "" {
		return nil
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 0 {
		return fmt.Errorf("invalid DB_MAX_OPEN_CONNS %q: want a non-negative integer", v)
	}
	db.SetMaxOpenConns(n)
	logger.Info("Database connection pool configured", slog.Int("max_open_conns", n))
	return nil
}

// startPriceRefresher re-reads catalogue prices every PRICE_REFRESH_INTERVAL
// (a Go duration such as "60s"; unset disables it) and logs when a price was
// changed directly in the database, so the change is visible without a restart.
// The goroutine stops when ctx is cancelled.
func startPriceRefresher(ctx context.Context) {
	v := os.Getenv("PRICE_REFRESH_INTERVAL")
	if v == "" {
		return
	}
	interval, err := time.ParseDuration(v)
	if err != nil || interval <= 0 {
		logger.Error("Invalid PRICE_REFRESH_INTERVAL, price refresh disabled", slog.String("value", v))
		return
	}
	logger.Info("Price refresh enabled", slog.Duration("interval", interval))

	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		known := map[string]int64{}
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
			if err := refreshPrices(ctx, known); err != nil {
				logger.Warn("Price refresh failed", slog.Any("error", err))
			}
		}
	}()
}

// refreshPrices reads every product's price in one consistent snapshot and
// records which ones changed since the previous read.
func refreshPrices(ctx context.Context, known map[string]int64) error {
	tx, err := db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true, Isolation: sql.LevelRepeatableRead})
	if err != nil {
		return fmt.Errorf("refreshPrices: begin: %w", err)
	}

	rows, err := tx.QueryContext(ctx, `SELECT id, price_units FROM catalog.products`)
	if err != nil {
		_ = tx.Rollback()
		return fmt.Errorf("refreshPrices: query: %w", err)
	}
	changed := 0
	for rows.Next() {
		var id string
		var units int64
		if err := rows.Scan(&id, &units); err != nil {
			_ = rows.Close()
			_ = tx.Rollback()
			return fmt.Errorf("refreshPrices: scan: %w", err)
		}
		if old, ok := known[id]; ok && old != units {
			changed++
		}
		known[id] = units
	}
	_ = rows.Close()
	if err := rows.Err(); err != nil {
		_ = tx.Rollback()
		return fmt.Errorf("refreshPrices: rows: %w", err)
	}

	if changed == 0 {
		_ = tx.Rollback()
		return nil
	}
	logger.Info("Catalogue prices changed", slog.Int("products", changed))
	return tx.Commit()
}

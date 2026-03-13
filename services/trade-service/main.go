// trade-service — minimal ETRM trade service stub
//
// Exposes:
//   GET  /health          — liveness probe (Kubernetes / Docker healthcheck)
//   GET  /readyz          — readiness probe (checks DB connectivity)
//   GET  /trades          — list seed trades (returns hardcoded JSON until MSSQL wired)
//   GET  /trades/:id      — single trade by unique_id
//   GET  /metrics         — Prometheus metrics (request count, latency, trade gauge)
//
// This is a learning scaffold. Students extend it in Lab 10:
//   - Wire MSSQL queries (replace hardcoded trades)
//   - Add POST /trades with Kafka publishing
//   - Add /pnl/:trade_id that queries ClickHouse
//   - Add credit check via MDM service API
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// ── Domain types ────────────────────────────────────────────────

type Trade struct {
	TradeID           int       `json:"trade_id"`
	UniqueID          string    `json:"unique_id"`
	CounterpartyMDMID string    `json:"counterparty_mdm_id"`
	TotalQuantity     float64   `json:"total_quantity"`
	TradeAt           time.Time `json:"trade_at_utc"`
	IsActive          bool      `json:"is_active"`
}

type HealthResponse struct {
	Status    string `json:"status"`
	Service   string `json:"service"`
	Version   string `json:"version"`
	Timestamp string `json:"timestamp"`
}

// ── Seed data (mirrors MSSQL init_mssql.sql) ────────────────────
// In Lab 10, students replace this with real MSSQL queries.

var seedTrades = []Trade{
	{1, "TRADE-JP-001", "MDM-001", 100, time.Date(2025, 1, 15, 9, 0, 0, 0, time.UTC), true},
	{2, "TRADE-AU-001", "MDM-002", 50, time.Date(2025, 1, 16, 2, 0, 0, 0, time.UTC), true},
	{3, "TRADE-NZ-001", "MDM-003", 75, time.Date(2025, 1, 17, 21, 0, 0, 0, time.UTC), true},
	{4, "TRADE-JP-002", "MDM-001", 200, time.Date(2025, 1, 20, 6, 30, 0, 0, time.UTC), true},
	{5, "TRADE-AU-002", "MDM-002", 80, time.Date(2025, 1, 22, 3, 0, 0, 0, time.UTC), true},
}

// ── Prometheus metrics ──────────────────────────────────────────

var (
	httpRequestsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "trade_service_http_requests_total",
			Help: "Total HTTP requests by method, path, and status code",
		},
		[]string{"method", "path", "status"},
	)

	httpRequestDuration = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "trade_service_http_request_duration_seconds",
			Help:    "HTTP request latency in seconds",
			Buckets: prometheus.DefBuckets,
		},
		[]string{"method", "path"},
	)

	activeTrades = prometheus.NewGauge(
		prometheus.GaugeOpts{
			Name: "trade_service_active_trades",
			Help: "Number of active trades in the system",
		},
	)

	goldenRecords = prometheus.NewGauge(
		prometheus.GaugeOpts{
			Name: "trade_service_golden_records",
			Help: "Number of golden records known to the trade service (from MDM cache)",
		},
	)
)

func init() {
	prometheus.MustRegister(httpRequestsTotal)
	prometheus.MustRegister(httpRequestDuration)
	prometheus.MustRegister(activeTrades)
	prometheus.MustRegister(goldenRecords)

	// Set initial gauge values from seed data
	activeCount := 0
	for _, t := range seedTrades {
		if t.IsActive {
			activeCount++
		}
	}
	activeTrades.Set(float64(activeCount))
	goldenRecords.Set(3) // MDM-001, MDM-002, MDM-003
}

// ── Middleware ───────────────────────────────────────────────────

func metricsMiddleware(path string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: 200}
		next(rec, r)
		duration := time.Since(start).Seconds()

		httpRequestsTotal.WithLabelValues(r.Method, path, fmt.Sprintf("%d", rec.status)).Inc()
		httpRequestDuration.WithLabelValues(r.Method, path).Observe(duration)
	}
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

// ── Handlers ────────────────────────────────────────────────────

func handleHealth(w http.ResponseWriter, r *http.Request) {
	resp := HealthResponse{
		Status:    "ok",
		Service:   "trade-service",
		Version:   "0.1.0-stub",
		Timestamp: time.Now().UTC().Format(time.RFC3339),
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func handleReadyz(w http.ResponseWriter, r *http.Request) {
	// In Lab 10, students add real DB connectivity checks here:
	//   - Ping MSSQL
	//   - Ping ClickHouse
	//   - Check Redis connection
	//   - Check Kafka broker availability
	resp := map[string]interface{}{
		"status": "ok",
		"checks": map[string]string{
			"mssql":      "stub_ok",
			"clickhouse": "stub_ok",
			"redis":      "stub_ok",
			"kafka":      "stub_ok",
		},
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func handleListTrades(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(seedTrades)
}

func handleGetTrade(w http.ResponseWriter, r *http.Request) {
	// Extract trade ID from path: /trades/TRADE-JP-001
	path := strings.TrimPrefix(r.URL.Path, "/trades/")
	if path == "" || path == r.URL.Path {
		http.Error(w, `{"error":"trade unique_id required"}`, http.StatusBadRequest)
		return
	}

	for _, t := range seedTrades {
		if t.UniqueID == path {
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(t)
			return
		}
	}

	w.WriteHeader(http.StatusNotFound)
	fmt.Fprintf(w, `{"error":"trade %s not found"}`, path)
}

// ── Main ────────────────────────────────────────────────────────

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	mux := http.NewServeMux()

	// Health & readiness
	mux.HandleFunc("/health", metricsMiddleware("/health", handleHealth))
	mux.HandleFunc("/readyz", metricsMiddleware("/readyz", handleReadyz))

	// Trade endpoints
	mux.HandleFunc("/trades", metricsMiddleware("/trades", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/trades" || r.URL.Path == "/trades/" {
			handleListTrades(w, r)
		} else {
			handleGetTrade(w, r)
		}
	}))
	// Also handle /trades/<id> paths
	mux.HandleFunc("/trades/", metricsMiddleware("/trades/{id}", handleGetTrade))

	// Prometheus metrics
	mux.Handle("/metrics", promhttp.Handler())

	log.Printf("trade-service starting on :%s", port)
	log.Printf("  GET /health          — liveness probe")
	log.Printf("  GET /readyz          — readiness probe")
	log.Printf("  GET /trades          — list all trades")
	log.Printf("  GET /trades/:id      — get trade by unique_id")
	log.Printf("  GET /metrics         — Prometheus metrics")

	if err := http.ListenAndServe(":"+port, mux); err != nil {
		log.Fatalf("server failed: %v", err)
	}
}

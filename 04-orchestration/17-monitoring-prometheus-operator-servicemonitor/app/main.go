package main

import (
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

type MetricsStore struct {
	mu                   sync.RWMutex
	requestsTotal        map[string]uint64 // key: handler:method:code
	durationBuckets      map[string]uint64 // key: handler:le
	durationSum          float64
	durationCount        uint64
	errorSimulationOn    bool
	latencySimulationMs  int
}

var store = &MetricsStore{
	requestsTotal:   make(map[string]uint64),
	durationBuckets: make(map[string]uint64),
}

var totalRequests uint64

func getEnv(key, fallback string) string {
	if val, ok := os.LookupEnv(key); ok {
		return val
	}
	return fallback
}

func recordRequest(handler, method, code string, durationSec float64) {
	store.mu.Lock()
	defer store.mu.Unlock()

	key := fmt.Sprintf("%s:%s:%s", handler, method, code)
	store.requestsTotal[key]++

	store.durationCount++
	store.durationSum += durationSec

	// Buckets: 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, +Inf
	buckets := []float64{0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0}
	for _, b := range buckets {
		if durationSec <= b {
			bKey := fmt.Sprintf("%s:%.2f", handler, b)
			store.durationBuckets[bKey]++
		}
	}
	store.durationBuckets[fmt.Sprintf("%s:+Inf", handler)]++
}

func main() {
	port := getEnv("PORT", "8080")
	appName := getEnv("APP_NAME", "order-processing-api")
	version := getEnv("APP_VERSION", "v1.0.0")

	log.Printf("[INIT] Starting Monitored Application [%s (%s)] on Port :%s", appName, version, port)

	// Primary application endpoint
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		atomic.AddUint64(&totalRequests, 1)

		store.mu.RLock()
		errSim := store.errorSimulationOn
		latMs := store.latencySimulationMs
		store.mu.RUnlock()

		if latMs > 0 {
			time.Sleep(time.Duration(latMs) * time.Millisecond)
		}

		code := "200"
		if errSim && rand.Float64() < 0.6 {
			code = "500"
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusInternalServerError)
			_ = json.NewEncoder(w).Encode(map[string]string{
				"status":  "error",
				"message": "Simulated downstream payment gateway failure",
			})
		} else {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			_ = json.NewEncoder(w).Encode(map[string]interface{}{
				"status":  "success",
				"service": appName,
				"version": version,
				"time":    time.Now().UTC().Format(time.RFC3339),
			})
		}

		duration := time.Since(start).Seconds()
		recordRequest("/", r.Method, code, duration)
	})

	// Prometheus Scrape Endpoint
	http.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		store.mu.RLock()
		defer store.mu.RUnlock()

		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		w.WriteHeader(http.StatusOK)

		fmt.Fprintf(w, "# HELP app_up Indicates if the application is running\n")
		fmt.Fprintf(w, "# TYPE app_up gauge\n")
		fmt.Fprintf(w, "app_up{app=\"%s\",version=\"%s\"} 1\n", appName, version)

		fmt.Fprintf(w, "# HELP http_requests_total Total number of HTTP requests processed\n")
		fmt.Fprintf(w, "# TYPE http_requests_total counter\n")
		for key, count := range store.requestsTotal {
			var handler, method, code string
			_, _ = fmt.Sscanf(key, "%s:%s:%s", &handler, &method, &code)
			fmt.Fprintf(w, "http_requests_total{app=\"%s\",handler=\"%s\",method=\"%s\",code=\"%s\"} %d\n",
				appName, handler, method, code, count)
		}

		fmt.Fprintf(w, "# HELP http_request_duration_seconds HTTP request latency histogram\n")
		fmt.Fprintf(w, "# TYPE http_request_duration_seconds histogram\n")
		for bKey, count := range store.durationBuckets {
			var handler, le string
			_, _ = fmt.Sscanf(bKey, "%s:%s", &handler, &le)
			fmt.Fprintf(w, "http_request_duration_seconds_bucket{app=\"%s\",handler=\"%s\",le=\"%s\"} %d\n",
				appName, handler, le, count)
		}
		fmt.Fprintf(w, "http_request_duration_seconds_sum{app=\"%s\",handler=\"/\"} %f\n", appName, store.durationSum)
		fmt.Fprintf(w, "http_request_duration_seconds_count{app=\"%s\",handler=\"/\"} %d\n", appName, store.durationCount)

		simErrVal := 0
		if store.errorSimulationOn {
			simErrVal = 1
		}
		fmt.Fprintf(w, "# HELP app_simulated_error_active Indicates whether synthetic error rate is injected\n")
		fmt.Fprintf(w, "# TYPE app_simulated_error_active gauge\n")
		fmt.Fprintf(w, "app_simulated_error_active{app=\"%s\"} %d\n", appName, simErrVal)
	})

	// Error simulation toggle
	http.HandleFunc("/simulate-errors", func(w http.ResponseWriter, r *http.Request) {
		store.mu.Lock()
		store.errorSimulationOn = true
		store.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"error_simulation_enabled","rate":"60%"}`))
	})

	// Latency simulation toggle
	http.HandleFunc("/simulate-latency", func(w http.ResponseWriter, r *http.Request) {
		msStr := r.URL.Query().Get("ms")
		ms, err := strconv.Atoi(msStr)
		if err != nil || ms <= 0 {
			ms = 350
		}
		store.mu.Lock()
		store.latencySimulationMs = ms
		store.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(fmt.Sprintf(`{"status":"latency_simulation_enabled","delay_ms":%d}`, ms)))
	})

	// Reset simulations
	http.HandleFunc("/reset", func(w http.ResponseWriter, r *http.Request) {
		store.mu.Lock()
		store.errorSimulationOn = false
		store.latencySimulationMs = 0
		store.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"simulations_reset"}`))
	})

	// Health check
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"healthy"}`))
	})

	server := &http.Server{
		Addr:         ":" + port,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
	}

	log.Printf("[READY] Monitored App listening on port :%s", port)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("[FATAL] Server error: %v", err)
	}
}

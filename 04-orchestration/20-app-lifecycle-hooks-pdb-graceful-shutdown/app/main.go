package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"
)

type AppStatus struct {
	ServiceName   string `json:"service_name"`
	PodName       string `json:"pod_name"`
	SchemaVersion string `json:"schema_version"`
	ActiveWorkers int64  `json:"active_workers"`
	State         string `json:"state"`
	UptimeSeconds int64  `json:"uptime_seconds"`
}

var (
	startTime      = time.Now()
	isDraining     atomic.Bool
	activeRequests int64
)

func getEnv(key, fallback string) string {
	if val, ok := os.LookupEnv(key); ok {
		return val
	}
	return fallback
}

func readSchemaVersion() string {
	schemaPath := getEnv("SCHEMA_FILE_PATH", "/etc/app-init/schema-version.txt")
	data, err := os.ReadFile(schemaPath)
	if err != nil {
		return "schema-v1.0-default"
	}
	return string(data)
}

func main() {
	port := getEnv("PORT", "8080")
	serviceName := getEnv("SERVICE_NAME", "order-processing-service")
	podName := getEnv("POD_NAME", "lifecycle-pod-local")
	schemaVersion := readSchemaVersion()

	log.Printf("[INIT] Starting %s on Pod %s (Schema: %s) Port :%s",
		serviceName, podName, schemaVersion, port)

	mux := http.NewServeMux()

	// Primary application status endpoint
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		status := AppStatus{
			ServiceName:   serviceName,
			PodName:       podName,
			SchemaVersion: schemaVersion,
			ActiveWorkers: atomic.LoadInt64(&activeRequests),
			State:         "RUNNING",
			UptimeSeconds: int64(time.Since(startTime).Seconds()),
		}
		if isDraining.Load() {
			status.State = "DRAINING"
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(status)
	})

	// Simulated heavy transaction workload endpoint
	mux.HandleFunc("/work", func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt64(&activeRequests, 1)
		defer atomic.AddInt64(&activeRequests, -1)

		msStr := r.URL.Query().Get("duration_ms")
		ms, err := strconv.Atoi(msStr)
		if err != nil || ms <= 0 {
			ms = 200
		}

		time.Sleep(time.Duration(ms) * time.Millisecond)

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(fmt.Sprintf(`{"status":"completed","processed_by":"%s","duration_ms":%d}`, podName, ms)))
	})

	// Liveness probe (process is running)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"healthy"}`))
	})

	// Readiness probe (ready to receive traffic; fails when draining)
	mux.HandleFunc("/ready", func(w http.ResponseWriter, r *http.Request) {
		if isDraining.Load() {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = w.Write([]byte(`{"status":"draining","accepting_traffic":false}`))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"ready","accepting_traffic":true}`))
	})

	server := &http.Server{
		Addr:         ":" + port,
		Handler:      mux,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 15 * time.Second,
	}

	// Server goroutine
	go func() {
		log.Printf("[READY] HTTP server listening on port :%s", port)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("[FATAL] Server terminated unexpectedly: %v", err)
		}
	}()

	// Graceful shutdown signal listener
	stopChan := make(chan os.Signal, 1)
	signal.Notify(stopChan, os.Interrupt, syscall.SIGTERM, syscall.SIGINT)

	sig := <-stopChan
	log.Printf("[LIFECYCLE] Received termination signal: %v. Initiating graceful drain...", sig)
	isDraining.Store(true)

	// Context for draining inflight requests
	drainTimeoutSec := 15
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(drainTimeoutSec)*time.Second)
	defer cancel()

	log.Printf("[LIFECYCLE] Waiting up to %ds for inflight requests to complete (active: %d)...",
		drainTimeoutSec, atomic.LoadInt64(&activeRequests))

	if err := server.Shutdown(ctx); err != nil {
		log.Printf("[ERROR] Server shutdown encountered error: %v", err)
	}

	log.Printf("[LIFECYCLE] All connections drained cleanly. Container exiting gracefully.")
}

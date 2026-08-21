package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

var (
	appVersion = "v1.0.0"
	mu         sync.RWMutex
	errorRate  = 0.0
	reqCounter uint64
	startTime  = time.Now()
)

type StatusResponse struct {
	App           string    `json:"app"`
	Version       string    `json:"version"`
	PodName       string    `json:"pod_name"`
	PodNamespace  string    `json:"pod_namespace"`
	PodIP         string    `json:"pod_ip"`
	Status        string    `json:"status"`
	ErrorRate     float64   `json:"error_rate"`
	RequestCount  uint64    `json:"request_count"`
	UptimeSeconds float64   `json:"uptime_seconds"`
	Timestamp     time.Time `json:"timestamp"`
}

func getEnv(key, fallback string) string {
	if val, ok := os.LookupEnv(key); ok && val != "" {
		return val
	}
	return fallback
}

func main() {
	port := getEnv("PORT", "8080")
	if v := getEnv("APP_VERSION", ""); v != "" {
		appVersion = v
	}

	if r := getEnv("ERROR_RATE", ""); r != "" {
		if rate, err := strconv.ParseFloat(r, 64); err == nil {
			errorRate = rate
			log.Printf("[INIT] Injected default error rate: %.2f", errorRate)
		}
	}

	podName := getEnv("POD_NAME", "rollout-pod-local")
	podNamespace := getEnv("POD_NAMESPACE", "argo-rollouts-demo")
	podIP := getEnv("POD_IP", "127.0.0.1")

	mux := http.NewServeMux()

	// GET / - Main workload traffic endpoint with synthetic error injection
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}

		count := atomic.AddUint64(&reqCounter, 1)

		mu.RLock()
		currentErrorRate := errorRate
		mu.RUnlock()

		// Simulate synthetic HTTP 500 error if random sample falls within errorRate
		if currentErrorRate > 0.0 && rand.Float64() < currentErrorRate {
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("X-Rollout-Version", appVersion)
			w.WriteHeader(http.StatusInternalServerError)
			_ = json.NewEncoder(w).Encode(map[string]interface{}{
				"error":      "Synthetic 500 internal server error triggered by fault injection",
				"version":    appVersion,
				"pod":        podName,
				"error_rate": currentErrorRate,
			})
			return
		}

		resp := StatusResponse{
			App:           "rollout-sample-microservice",
			Version:       appVersion,
			PodName:       podName,
			PodNamespace:  podNamespace,
			PodIP:         podIP,
			Status:        "healthy",
			ErrorRate:     currentErrorRate,
			RequestCount:  count,
			UptimeSeconds: time.Since(startTime).Seconds(),
			Timestamp:     time.Now().UTC(),
		}

		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Rollout-Version", appVersion)
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(resp)
	})

	// GET /version - Plain text version for lightweight scripts
	mux.HandleFunc("/version", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("X-Rollout-Version", appVersion)
		w.WriteHeader(http.StatusOK)
		_, _ = fmt.Fprintln(w, appVersion)
	})

	// POST /inject-error?rate=0.8 - Dynamic fault injection
	mux.HandleFunc("/inject-error", func(w http.ResponseWriter, r *http.Request) {
		rateStr := r.URL.Query().Get("rate")
		if rateStr == "" {
			rateStr = "1.0"
		}
		newRate, err := strconv.ParseFloat(rateStr, 64)
		if err != nil || newRate < 0.0 || newRate > 1.0 {
			http.Error(w, "Invalid rate (must be between 0.0 and 1.0)", http.StatusBadRequest)
			return
		}

		mu.Lock()
		errorRate = newRate
		mu.Unlock()

		log.Printf("[SECURITY/TEST] Updated error rate to: %.2f", newRate)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"message":    "Error rate updated successfully",
			"error_rate": newRate,
			"version":    appVersion,
			"pod":        podName,
		})
	})

	// Health probes
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "alive", "version": appVersion})
	})

	mux.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "ready", "version": appVersion})
	})

	server := &http.Server{
		Addr:         ":" + port,
		Handler:      mux,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  30 * time.Second,
	}

	go func() {
		log.Printf("[INFO] Rollout Microservice (%s) listening on :%s (Pod: %s)", appVersion, port, podName)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("[FATAL] Server error: %v", err)
		}
	}()

	shutdownChan := make(chan os.Signal, 1)
	signal.Notify(shutdownChan, os.Interrupt, syscall.SIGTERM, syscall.SIGINT)

	sig := <-shutdownChan
	log.Printf("[INFO] Signal %v received. Draining connections...", sig)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		log.Printf("[ERROR] Server shutdown error: %v", err)
	} else {
		log.Printf("[INFO] Rollout microservice stopped gracefully.")
	}
}

package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"sync/atomic"
	"syscall"
	"time"
)

// Config holds runtime application configuration injected via environment variables.
type Config struct {
	Port         string
	Version      string
	Environment  string
	PodName      string
	PodNamespace string
	PodIP        string
	NodeName     string
}

// AppResponse represents the standard JSON response for the root endpoint.
type AppResponse struct {
	Message       string    `json:"message"`
	Version       string    `json:"version"`
	Hostname      string    `json:"hostname"`
	PodName       string    `json:"pod_name"`
	PodNamespace  string    `json:"pod_namespace"`
	PodIP         string    `json:"pod_ip"`
	NodeName      string    `json:"node_name"`
	Environment   string    `json:"environment"`
	Timestamp     time.Time `json:"timestamp"`
	UptimeSeconds float64   `json:"uptime_seconds"`
	RequestCount  uint64    `json:"request_count"`
}

// HealthStatus represents the payload returned by health and readiness probes.
type HealthStatus struct {
	Status        string    `json:"status"`
	Probe         string    `json:"probe"`
	PodName       string    `json:"pod_name"`
	Version       string    `json:"version"`
	Timestamp     time.Time `json:"timestamp"`
	UptimeSeconds float64   `json:"uptime_seconds"`
}

// InfoResponse provides runtime diagnostic data for SRE observability.
type InfoResponse struct {
	App         AppResponse       `json:"app"`
	GoVersion   string            `json:"go_version"`
	NumCPU      int               `json:"num_cpu"`
	NumGoroutine int              `json:"num_goroutine"`
	MemoryAlloc uint64            `json:"memory_alloc_bytes"`
	Headers     map[string]string `json:"request_headers"`
}

var (
	startTime    = time.Now()
	requestCount uint64
	isReady      atomic.Bool
	isAlive      atomic.Bool
)

func getEnv(key, fallback string) string {
	if value, exists := os.LookupEnv(key); exists && value != "" {
		return value
	}
	return fallback
}

func main() {
	// Initialize atomic health states
	isReady.Store(true)
	isAlive.Store(true)

	hostname, err := os.Hostname()
	if err != nil {
		hostname = "unknown-host"
	}

	cfg := Config{
		Port:         getEnv("PORT", "8080"),
		Version:      getEnv("APP_VERSION", "v1.0.0"),
		Environment:  getEnv("ENVIRONMENT", "production"),
		PodName:      getEnv("POD_NAME", hostname),
		PodNamespace: getEnv("POD_NAMESPACE", "stateless-app-demo"),
		PodIP:        getEnv("POD_IP", "127.0.0.1"),
		NodeName:     getEnv("NODE_NAME", "kubernetes-node"),
	}

	mux := http.NewServeMux()

	// Root Endpoint: Stateless API payload
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}

		count := atomic.AddUint64(&requestCount, 1)
		uptime := time.Since(startTime).Seconds()

		resp := AppResponse{
			Message:       "Stateless microservice is running successfully on Kubernetes!",
			Version:       cfg.Version,
			Hostname:      hostname,
			PodName:       cfg.PodName,
			PodNamespace:  cfg.PodNamespace,
			PodIP:         cfg.PodIP,
			NodeName:      cfg.NodeName,
			Environment:   cfg.Environment,
			Timestamp:     time.Now().UTC(),
			UptimeSeconds: uptime,
			RequestCount:  count,
		}

		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-App-Version", cfg.Version)
		w.Header().Set("X-Pod-Name", cfg.PodName)
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(resp)
	})

	// Liveness Probe Endpoint: /healthz
	// Returns 200 OK if process is healthy. If failed, kubelet restarts the container.
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if !isAlive.Load() {
			w.WriteHeader(http.StatusServiceUnavailable)
			_ = json.NewEncoder(w).Encode(HealthStatus{
				Status:        "unhealthy",
				Probe:         "liveness",
				PodName:       cfg.PodName,
				Version:       cfg.Version,
				Timestamp:     time.Now().UTC(),
				UptimeSeconds: time.Since(startTime).Seconds(),
			})
			return
		}

		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(HealthStatus{
			Status:        "alive",
			Probe:         "liveness",
			PodName:       cfg.PodName,
			Version:       cfg.Version,
			Timestamp:     time.Now().UTC(),
			UptimeSeconds: time.Since(startTime).Seconds(),
		})
	})

	// Readiness Probe Endpoint: /readyz
	// Returns 200 OK if pod is ready to accept traffic. If failed, service removes pod from endpoints.
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if !isReady.Load() {
			w.WriteHeader(http.StatusServiceUnavailable)
			_ = json.NewEncoder(w).Encode(HealthStatus{
				Status:        "not_ready",
				Probe:         "readiness",
				PodName:       cfg.PodName,
				Version:       cfg.Version,
				Timestamp:     time.Now().UTC(),
				UptimeSeconds: time.Since(startTime).Seconds(),
			})
			return
		}

		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(HealthStatus{
			Status:        "ready",
			Probe:         "readiness",
			PodName:       cfg.PodName,
			Version:       cfg.Version,
			Timestamp:     time.Now().UTC(),
			UptimeSeconds: time.Since(startTime).Seconds(),
		})
	})

	// Diagnostic Info Endpoint: /info
	mux.HandleFunc("/info", func(w http.ResponseWriter, r *http.Request) {
		var m runtime.MemStats
		runtime.ReadMemStats(&m)

		headers := make(map[string]string)
		for k, v := range r.Header {
			if len(v) > 0 {
				headers[k] = v[0]
			}
		}

		count := atomic.LoadUint64(&requestCount)
		resp := InfoResponse{
			App: AppResponse{
				Message:       "Stateless microservice diagnostic info",
				Version:       cfg.Version,
				Hostname:      hostname,
				PodName:       cfg.PodName,
				PodNamespace:  cfg.PodNamespace,
				PodIP:         cfg.PodIP,
				NodeName:      cfg.NodeName,
				Environment:   cfg.Environment,
				Timestamp:     time.Now().UTC(),
				UptimeSeconds: time.Since(startTime).Seconds(),
				RequestCount:  count,
			},
			GoVersion:    runtime.Version(),
			NumCPU:       runtime.NumCPU(),
			NumGoroutine: runtime.NumGoroutine(),
			MemoryAlloc:  m.Alloc,
			Headers:      headers,
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(resp)
	})

	// Toggle Health / Readiness for testing probe behavior
	mux.HandleFunc("/toggle-ready", func(w http.ResponseWriter, r *http.Request) {
		current := isReady.Load()
		newState := !current
		isReady.Store(newState)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"action":   "toggle-readiness",
			"is_ready": newState,
			"pod_name": cfg.PodName,
		})
	})

	mux.HandleFunc("/toggle-alive", func(w http.ResponseWriter, r *http.Request) {
		current := isAlive.Load()
		newState := !current
		isAlive.Store(newState)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"action":   "toggle-liveness",
			"is_alive": newState,
			"pod_name": cfg.PodName,
		})
	})

	server := &http.Server{
		Addr:         ":" + cfg.Port,
		Handler:      mux,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  30 * time.Second,
	}

	// Server startup in background goroutine
	go func() {
		log.Printf("[INFO] Stateless App starting on port %s (Version: %s, Pod: %s, Node: %s)",
			cfg.Port, cfg.Version, cfg.PodName, cfg.NodeName)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("[FATAL] HTTP server ListenAndServe error: %v", err)
		}
	}()

	// Graceful shutdown handling on SIGTERM and SIGINT
	shutdownChan := make(chan os.Signal, 1)
	signal.Notify(shutdownChan, os.Interrupt, syscall.SIGTERM, syscall.SIGINT)

	sig := <-shutdownChan
	log.Printf("[INFO] Received signal %v. Initiating graceful shutdown sequence...", sig)

	// Context with timeout to drain ongoing requests
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		log.Printf("[ERROR] Server forced to shutdown due to error: %v", err)
	} else {
		log.Printf("[INFO] Server stopped gracefully. Active connections drained successfully.")
	}
}

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"sync/atomic"
	"syscall"
	"time"
)

type PodMetadata struct {
	PodName      string `json:"pod_name"`
	PodNamespace string `json:"pod_namespace"`
	PodIP        string `json:"pod_ip"`
	NodeName     string `json:"node_name"`
}

type ConfigInfo struct {
	AppName      string `json:"app_name"`
	Environment  string `json:"environment"`
	LogLevel     string `json:"log_level"`
	Version      string `json:"version"`
	FeatureFlags string `json:"feature_flags"`
}

type APIResponse struct {
	Service       string       `json:"service"`
	Message       string       `json:"message"`
	Config        ConfigInfo   `json:"config"`
	Pod           PodMetadata  `json:"pod"`
	Timestamp     time.Time    `json:"timestamp"`
	UptimeSeconds float64      `json:"uptime_seconds"`
	RequestCount  uint64       `json:"request_count"`
}

var (
	startTime    = time.Now()
	requestCount uint64
)

func getEnv(key, fallback string) string {
	if val, ok := os.LookupEnv(key); ok && val != "" {
		return val
	}
	return fallback
}

func main() {
	port := getEnv("PORT", "8080")

	hostname, err := os.Hostname()
	if err != nil {
		hostname = "enterprise-app-0"
	}

	pod := PodMetadata{
		PodName:      getEnv("POD_NAME", hostname),
		PodNamespace: getEnv("POD_NAMESPACE", "helm-demo"),
		PodIP:        getEnv("POD_IP", "127.0.0.1"),
		NodeName:     getEnv("NODE_NAME", "kubernetes-node"),
	}

	config := ConfigInfo{
		AppName:      getEnv("APP_NAME", "Enterprise-Microservice"),
		Environment:  getEnv("ENVIRONMENT", "production"),
		LogLevel:     getEnv("LOG_LEVEL", "INFO"),
		Version:      getEnv("APP_VERSION", "v1.0.0"),
		FeatureFlags: getEnv("FEATURE_FLAGS", "analytics=true,cache=true"),
	}

	mux := http.NewServeMux()

	// GET /
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}

		count := atomic.AddUint64(&requestCount, 1)
		resp := APIResponse{
			Service:       config.AppName,
			Message:       "Production-grade Helm 3 packaged microservice running successfully!",
			Config:        config,
			Pod:           pod,
			Timestamp:     time.Now().UTC(),
			UptimeSeconds: time.Since(startTime).Seconds(),
			RequestCount:  count,
		}

		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-App-Version", config.Version)
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(resp)
	})

	// GET /config
	mux.HandleFunc("/config", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(config)
	})

	// GET /metrics
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		uptime := time.Since(startTime).Seconds()
		reqs := atomic.LoadUint64(&requestCount)

		metrics := fmt.Sprintf(`# HELP http_requests_total Total number of HTTP requests processed.
# TYPE http_requests_total counter
http_requests_total{app="%s",env="%s"} %d

# HELP app_uptime_seconds Total application uptime in seconds.
# TYPE app_uptime_seconds gauge
app_uptime_seconds{app="%s"} %.2f

# HELP app_goroutines_count Current number of active goroutines.
# TYPE app_goroutines_count gauge
app_goroutines_count{app="%s"} %d
`, config.AppName, config.Environment, reqs, config.AppName, uptime, config.AppName, runtime.NumGoroutine())

		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(metrics))
	})

	// Health Probes
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "alive", "app": config.AppName, "pod": pod.PodName})
	})

	mux.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "ready", "app": config.AppName, "pod": pod.PodName})
	})

	server := &http.Server{
		Addr:         ":" + port,
		Handler:      mux,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  30 * time.Second,
	}

	go func() {
		log.Printf("[INFO] %s (%s) listening on :%s (Pod: %s, Node: %s)",
			config.AppName, config.Version, port, pod.PodName, pod.NodeName)
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
		log.Printf("[INFO] Enterprise server stopped gracefully.")
	}
}

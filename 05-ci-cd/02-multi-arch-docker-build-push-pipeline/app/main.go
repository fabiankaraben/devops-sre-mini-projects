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

// InfoResponse defines the system architecture and runtime payload.
type InfoResponse struct {
	Service      string `json:"service"`
	OS           string `json:"os"`
	Architecture string `json:"architecture"`
	GoVersion    string `json:"go_version"`
	NumCPU       int    `json:"num_cpu"`
	Hostname     string `json:"hostname"`
	Timestamp    string `json:"timestamp"`
}

// HealthResponse defines the health check status payload.
type HealthResponse struct {
	Status    string `json:"status"`
	UptimeSec int64  `json:"uptime_seconds"`
	Timestamp string `json:"timestamp"`
}

var (
	startTime    = time.Now()
	requestCount uint64
)

func rootHandler(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	atomic.AddUint64(&requestCount, 1)

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]interface{}{
		"message":      "Multi-Architecture Cloud-Native Microservice",
		"architecture": runtime.GOARCH,
		"os":           runtime.GOOS,
		"status":       "running",
	})
}

func healthzHandler(w http.ResponseWriter, r *http.Request) {
	atomic.AddUint64(&requestCount, 1)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)

	resp := HealthResponse{
		Status:    "healthy",
		UptimeSec: int64(time.Since(startTime).Seconds()),
		Timestamp: time.Now().UTC().Format(time.RFC3339),
	}
	_ = json.NewEncoder(w).Encode(resp)
}

func infoHandler(w http.ResponseWriter, r *http.Request) {
	atomic.AddUint64(&requestCount, 1)
	hostname, err := os.Hostname()
	if err != nil {
		hostname = "unknown"
	}

	w.Header().Set("Content-Type", "application/json")
	resp := InfoResponse{
		Service:      "multiarch-demo-service",
		OS:           runtime.GOOS,
		Architecture: runtime.GOARCH,
		GoVersion:    runtime.Version(),
		NumCPU:       runtime.NumCPU(),
		Hostname:     hostname,
		Timestamp:    time.Now().UTC().Format(time.RFC3339),
	}
	_ = json.NewEncoder(w).Encode(resp)
}

func metricsHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	uptime := time.Since(startTime).Seconds()
	totalReqs := atomic.LoadUint64(&requestCount)

	fmt.Fprintf(w, "# HELP service_uptime_seconds Total runtime uptime in seconds\n")
	fmt.Fprintf(w, "# TYPE service_uptime_seconds gauge\n")
	fmt.Fprintf(w, "service_uptime_seconds %.2f\n", uptime)

	fmt.Fprintf(w, "# HELP service_requests_total Total number of HTTP requests served\n")
	fmt.Fprintf(w, "# TYPE service_requests_total counter\n")
	fmt.Fprintf(w, "service_requests_total %d\n", totalReqs)

	fmt.Fprintf(w, "# HELP service_go_info Build and architecture information\n")
	fmt.Fprintf(w, "# TYPE service_go_info gauge\n")
	fmt.Fprintf(w, "service_go_info{arch=\"%s\",os=\"%s\",version=\"%s\"} 1\n", runtime.GOARCH, runtime.GOOS, runtime.Version())
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", rootHandler)
	mux.HandleFunc("/healthz", healthzHandler)
	mux.HandleFunc("/info", infoHandler)
	mux.HandleFunc("/metrics", metricsHandler)

	server := &http.Server{
		Addr:         ":" + port,
		Handler:      mux,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	stopChan := make(chan os.Signal, 1)
	signal.Notify(stopChan, os.Interrupt, syscall.SIGTERM)

	go func() {
		log.Printf("Starting Multi-Arch Microservice [OS: %s, Arch: %s] on port %s", runtime.GOOS, runtime.GOARCH, port)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Server listen failed: %v", err)
		}
	}()

	<-stopChan
	log.Println("Shutting down microservice gracefully...")

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		log.Fatalf("Server forced shutdown failed: %v", err)
	}

	log.Println("Microservice exited cleanly.")
}

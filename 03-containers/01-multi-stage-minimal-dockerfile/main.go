package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"os/user"
	"runtime"
	"syscall"
	"time"
)

var (
	startTime = time.Now()
	version   = "1.0.0"
)

type Response struct {
	Message   string                 `json:"message"`
	Timestamp string                 `json:"timestamp"`
	Data      map[string]interface{} `json:"data,omitempty"`
}

func getPort() string {
	if p := os.Getenv("PORT"); p != "" {
		return p
	}
	return "8080"
}

func jsonResponse(w http.ResponseWriter, statusCode int, data interface{}) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(statusCode)
	if err := json.NewEncoder(w).Encode(data); err != nil {
		log.Printf("Error encoding JSON response: %v", err)
	}
}

func rootHandler(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		jsonResponse(w, http.StatusNotFound, map[string]string{
			"error": "Route not found",
		})
		return
	}

	hostname, _ := os.Hostname()
	jsonResponse(w, http.StatusOK, Response{
		Message:   "Welcome to the Multi-Stage Minimal Container Microservice",
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		Data: map[string]interface{}{
			"version":        version,
			"hostname":       hostname,
			"os":             runtime.GOOS,
			"arch":           runtime.GOARCH,
			"uptime_seconds": time.Since(startTime).Seconds(),
			"endpoints": []string{
				"GET /",
				"GET /health",
				"GET /info",
				"GET /metrics",
			},
		},
	})
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	jsonResponse(w, http.StatusOK, map[string]interface{}{
		"status":         "UP",
		"timestamp":      time.Now().UTC().Format(time.RFC3339),
		"uptime_seconds": time.Since(startTime).Seconds(),
	})
}

func infoHandler(w http.ResponseWriter, r *http.Request) {
	hostname, _ := os.Hostname()
	currentUID := os.Getuid()
	currentGID := os.Getgid()

	username := "unknown"
	if u, err := user.Current(); err == nil {
		username = u.Username
	} else {
		// Fallback for scratch/minimal images without libc getpwuid
		if currentUID == 0 {
			username = "root"
		} else if currentUID == 10001 {
			username = "appuser"
		}
	}

	jsonResponse(w, http.StatusOK, map[string]interface{}{
		"application": "minimal-container-demo",
		"version":     version,
		"security_context": map[string]interface{}{
			"uid":      currentUID,
			"gid":      currentGID,
			"username": username,
			"is_root":  currentUID == 0,
		},
		"system": map[string]interface{}{
			"hostname":       hostname,
			"go_version":     runtime.Version(),
			"num_cpu":        runtime.NumCPU(),
			"num_goroutine":  runtime.NumGoroutine(),
			"uptime_seconds": time.Since(startTime).Seconds(),
		},
	})
}

func metricsHandler(w http.ResponseWriter, r *http.Request) {
	var m runtime.MemStats
	runtime.ReadMemStats(&m)

	jsonResponse(w, http.StatusOK, map[string]interface{}{
		"memory": map[string]interface{}{
			"alloc_bytes":       m.Alloc,
			"total_alloc_bytes": m.TotalAlloc,
			"sys_bytes":         m.Sys,
			"num_gc":            m.NumGC,
		},
		"runtime": map[string]interface{}{
			"num_goroutine": runtime.NumGoroutine(),
			"num_cpu":       runtime.NumCPU(),
		},
	})
}

func loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s from %s in %v", r.Method, r.URL.Path, r.RemoteAddr, time.Since(start))
	})
}

func main() {
	port := getPort()
	addr := fmt.Sprintf(":%s", port)

	mux := http.NewServeMux()
	mux.HandleFunc("/", rootHandler)
	mux.HandleFunc("/health", healthHandler)
	mux.HandleFunc("/info", infoHandler)
	mux.HandleFunc("/metrics", metricsHandler)

	server := &http.Server{
		Addr:         addr,
		Handler:      loggingMiddleware(mux),
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  15 * time.Second,
	}

	// Channel to listen for interrupt signals
	stopChan := make(chan os.Signal, 1)
	signal.Notify(stopChan, os.Interrupt, syscall.SIGTERM)

	go func() {
		log.Printf("Starting HTTP server on %s (UID: %d, GID: %d)", addr, os.Getuid(), os.Getgid())
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Server failed to start: %v", err)
		}
	}()

	<-stopChan
	log.Println("Shutting down server gracefully...")

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		log.Fatalf("Server forced to shutdown: %v", err)
	}

	log.Println("Server exited cleanly.")
}

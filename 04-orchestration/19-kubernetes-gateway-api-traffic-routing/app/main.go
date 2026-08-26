package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"
)

type BackendResponse struct {
	ServiceName    string              `json:"service_name"`
	ServiceVersion string              `json:"service_version"`
	ColorTheme     string              `json:"color_theme"`
	Path           string              `json:"path"`
	Method         string              `json:"method"`
	Host           string              `json:"host"`
	Headers        map[string][]string `json:"headers"`
	PodName        string              `json:"pod_name"`
	Timestamp      string              `json:"timestamp"`
}

func getEnv(key, fallback string) string {
	if val, ok := os.LookupEnv(key); ok {
		return val
	}
	return fallback
}

func main() {
	port := getEnv("PORT", "8080")
	serviceName := getEnv("SERVICE_NAME", "backend-service")
	serviceVersion := getEnv("SERVICE_VERSION", "v1.0.0")
	colorTheme := getEnv("COLOR_THEME", "blue")
	podName := getEnv("POD_NAME", "unknown-pod")

	log.Printf("[INIT] Starting Gateway Backend [%s (%s)] Theme: %s on Port :%s",
		serviceName, serviceVersion, colorTheme, port)

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		headers := make(map[string][]string)
		for k, v := range r.Header {
			headers[k] = v
		}

		resp := BackendResponse{
			ServiceName:    serviceName,
			ServiceVersion: serviceVersion,
			ColorTheme:     colorTheme,
			Path:           r.URL.Path,
			Method:         r.Method,
			Host:           r.Host,
			Headers:        headers,
			PodName:        podName,
			Timestamp:      time.Now().UTC().Format(time.RFC3339),
		}

		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Backend-Version", serviceVersion)
		w.Header().Set("X-Backend-Service", serviceName)
		w.WriteHeader(http.StatusOK)

		if err := json.NewEncoder(w).Encode(resp); err != nil {
			log.Printf("[ERROR] Failed to encode JSON response: %v", err)
		}
	})

	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"healthy","version":"` + serviceVersion + `"}`))
	})

	server := &http.Server{
		Addr:         ":" + port,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
	}

	log.Printf("[READY] Backend HTTP Server listening on port :%s", port)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("[FATAL] Server terminated: %v", err)
	}
}

package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

// AppInfo represents the structured JSON response emitted by the payment service
type AppInfo struct {
	Service     string            `json:"service"`
	Environment string            `json:"environment"`
	Version     string            `json:"version"`
	Hostname    string            `json:"hostname"`
	Timestamp   string            `json:"timestamp"`
	Config      map[string]string `json:"config"`
	Secrets     map[string]string `json:"secrets_masked"`
	Headers     map[string]string `json:"request_headers,omitempty"`
}

// HealthStatus represents the response for liveness/readiness probes
type HealthStatus struct {
	Status    string `json:"status"`
	Service   string `json:"service"`
	Timestamp string `json:"timestamp"`
}

func getEnv(key, fallback string) string {
	if value, exists := os.LookupEnv(key); exists {
		return value
	}
	return fallback
}

func maskSecret(val string) string {
	if len(val) <= 4 {
		return "******"
	}
	return val[:2] + strings.Repeat("*", len(val)-4) + val[len(val)-2:]
}

func main() {
	port := getEnv("PORT", "8080")
	envName := getEnv("APP_ENV", "unspecified")
	appVersion := getEnv("APP_VERSION", "v1.0.0")
	logLevel := getEnv("LOG_LEVEL", "info")

	log.Printf("[INIT] Starting Payment Service (%s) on port %s in environment: %s [LogLevel: %s]",
		appVersion, port, envName, logLevel)

	// Root endpoint returning detailed environment and configuration metadata
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		hostname, err := os.Hostname()
		if err != nil {
			hostname = "unknown"
		}

		headers := make(map[string]string)
		for k, v := range r.Header {
			if len(v) > 0 {
				headers[k] = v[0]
			}
		}

		configMap := map[string]string{
			"LOG_LEVEL":           getEnv("LOG_LEVEL", "info"),
			"FEATURE_NEW_PAYMENT": getEnv("FEATURE_NEW_PAYMENT", "false"),
			"CACHE_TTL_SECONDS":   getEnv("CACHE_TTL_SECONDS", "300"),
			"MAX_RETRY_ATTEMPTS":  getEnv("MAX_RETRY_ATTEMPTS", "3"),
			"PAYMENT_GATEWAY_URL": getEnv("PAYMENT_GATEWAY_URL", "https://api.gateway.internal/v1"),
			"CURRENCY_DEFAULT":    getEnv("CURRENCY_DEFAULT", "USD"),
		}

		// Read masked secrets injected via secretGenerator
		secretsMap := map[string]string{
			"DB_PASSWORD":      maskSecret(getEnv("DB_PASSWORD", "none")),
			"API_KEY":          maskSecret(getEnv("API_KEY", "none")),
			"WEBHOOK_SIGN_KEY": maskSecret(getEnv("WEBHOOK_SIGN_KEY", "none")),
		}

		resp := AppInfo{
			Service:     "payment-service",
			Environment: envName,
			Version:     appVersion,
			Hostname:    hostname,
			Timestamp:   time.Now().UTC().Format(time.RFC3339),
			Config:      configMap,
			Secrets:     secretsMap,
			Headers:     headers,
		}

		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Environment", envName)
		w.Header().Set("X-Service-Version", appVersion)
		w.WriteHeader(http.StatusOK)

		if err := json.NewEncoder(w).Encode(resp); err != nil {
			log.Printf("[ERROR] Failed to encode JSON response: %v", err)
		}
	})

	// Health probes for Kubernetes liveness & readiness
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(HealthStatus{
			Status:    "healthy",
			Service:   "payment-service",
			Timestamp: time.Now().UTC().Format(time.RFC3339),
		})
	})

	http.HandleFunc("/ready", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(HealthStatus{
			Status:    "ready",
			Service:   "payment-service",
			Timestamp: time.Now().UTC().Format(time.RFC3339),
		})
	})

	server := &http.Server{
		Addr:         ":" + port,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
	}

	log.Printf("[READY] Payment Service listening on :%s", port)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("[FATAL] Server error: %v", err)
	}
}

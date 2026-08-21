package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

// AppConfig represents configuration injected via environment variables.
type AppConfig struct {
	AppName              string `json:"app_name"`
	Environment          string `json:"environment"`
	LogLevel             string `json:"log_level"`
	Theme                string `json:"theme"`
	FeatureFlagAnalytics bool   `json:"feature_flag_analytics"`
}

// SecretMetadata represents masked credentials for secure observability.
type SecretMetadata struct {
	APIKeyMasked     string `json:"api_key_masked"`
	DBPasswordLength int    `json:"db_password_length"`
	JWTKeyPresent    bool   `json:"jwt_key_present"`
	JWTKeySHA256     string `json:"jwt_key_sha256"`
}

// PodIdentity holds Downward API container metadata.
type PodIdentity struct {
	PodName      string `json:"pod_name"`
	PodNamespace string `json:"pod_namespace"`
	PodIP        string `json:"pod_ip"`
	NodeName     string `json:"node_name"`
}

// ResponsePayload defines the primary API response.
type ResponsePayload struct {
	Message       string                 `json:"message"`
	Pod           PodIdentity            `json:"pod"`
	EnvConfig     AppConfig              `json:"env_config"`
	VolumeConfig  map[string]interface{} `json:"volume_config_json"`
	SecretInfo    SecretMetadata         `json:"secret_metadata"`
	Timestamp     time.Time              `json:"timestamp"`
	UptimeSeconds float64                `json:"uptime_seconds"`
	RequestCount  uint64                 `json:"request_count"`
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

func maskSecret(s string) string {
	if len(s) <= 4 {
		return "****"
	}
	return s[:3] + strings.Repeat("*", len(s)-4) + s[len(s)-1:]
}

func readVolumeConfigFile(path string) map[string]interface{} {
	data, err := os.ReadFile(path)
	if err != nil {
		return map[string]interface{}{
			"error": "config file not found or unreadable: " + err.Error(),
			"path":  path,
		}
	}
	var parsed map[string]interface{}
	if err := json.Unmarshal(data, &parsed); err != nil {
		return map[string]interface{}{
			"error": "invalid json: " + err.Error(),
			"raw":   string(data),
		}
	}
	return parsed
}

func inspectSecretFile(path string) (bool, string) {
	data, err := os.ReadFile(path)
	if err != nil || len(data) == 0 {
		return false, ""
	}
	hash := sha256.Sum256(data)
	return true, hex.EncodeToString(hash[:])
}

func main() {
	port := getEnv("PORT", "8080")
	configFilePath := getEnv("CONFIG_FILE_PATH", "/etc/config/settings.json")
	secretFilePath := getEnv("SECRET_FILE_PATH", "/etc/secrets/jwt-signing.key")

	hostname, err := os.Hostname()
	if err != nil {
		hostname = "unknown-host"
	}

	pod := PodIdentity{
		PodName:      getEnv("POD_NAME", hostname),
		PodNamespace: getEnv("POD_NAMESPACE", "config-reloading-demo"),
		PodIP:        getEnv("POD_IP", "127.0.0.1"),
		NodeName:     getEnv("NODE_NAME", "kubernetes-node"),
	}

	mux := http.NewServeMux()

	// Root Endpoint: Consolidated environment and volume configuration
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}

		count := atomic.AddUint64(&requestCount, 1)

		// 1. Environment Config (loaded on container start from ConfigMap)
		envCfg := AppConfig{
			AppName:              getEnv("APP_NAME", "ConfigReloadingApp"),
			Environment:          getEnv("ENVIRONMENT", "development"),
			LogLevel:             getEnv("LOG_LEVEL", "INFO"),
			Theme:                getEnv("THEME", "dark"),
			FeatureFlagAnalytics: getEnv("FEATURE_FLAG_ANALYTICS", "false") == "true",
		}

		// 2. Volume Config (dynamically read from mounted ConfigMap volume)
		volCfg := readVolumeConfigFile(configFilePath)

		// 3. Secrets Metadata (masked and hashed for safe auditing)
		apiKey := getEnv("API_KEY", "")
		dbPass := getEnv("DB_PASSWORD", "")
		jwtPresent, jwtHash := inspectSecretFile(secretFilePath)

		secretMeta := SecretMetadata{
			APIKeyMasked:     maskSecret(apiKey),
			DBPasswordLength: len(dbPass),
			JWTKeyPresent:    jwtPresent,
			JWTKeySHA256:     jwtHash,
		}

		resp := ResponsePayload{
			Message:       "ConfigMap & Secret Dynamic Reloading Demo",
			Pod:           pod,
			EnvConfig:     envCfg,
			VolumeConfig:  volCfg,
			SecretInfo:    secretMeta,
			Timestamp:     time.Now().UTC(),
			UptimeSeconds: time.Since(startTime).Seconds(),
			RequestCount:  count,
		}

		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Pod-Name", pod.PodName)
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(resp)
	})

	// Detailed Config Endpoint: Exposes raw vs parsed configuration
	mux.HandleFunc("/config", func(w http.ResponseWriter, r *http.Request) {
		volCfg := readVolumeConfigFile(configFilePath)
		jwtPresent, jwtHash := inspectSecretFile(secretFilePath)

		payload := map[string]interface{}{
			"pod_name": pod.PodName,
			"environment_variables": map[string]string{
				"APP_NAME":               getEnv("APP_NAME", ""),
				"ENVIRONMENT":            getEnv("ENVIRONMENT", ""),
				"LOG_LEVEL":              getEnv("LOG_LEVEL", ""),
				"THEME":                  getEnv("THEME", ""),
				"FEATURE_FLAG_ANALYTICS": getEnv("FEATURE_FLAG_ANALYTICS", ""),
			},
			"volume_mounted_file": map[string]interface{}{
				"path":    configFilePath,
				"content": volCfg,
			},
			"secret_metadata": map[string]interface{}{
				"api_key_masked":  maskSecret(getEnv("API_KEY", "")),
				"jwt_key_present": jwtPresent,
				"jwt_key_sha256":  jwtHash,
			},
			"timestamp": time.Now().UTC(),
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(payload)
	})

	// Health probes
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "alive", "pod": pod.PodName})
	})

	mux.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "ready", "pod": pod.PodName})
	})

	server := &http.Server{
		Addr:         ":" + port,
		Handler:      mux,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  30 * time.Second,
	}

	go func() {
		log.Printf("[INFO] Config-reloading microservice listening on :%s (Pod: %s, Node: %s)",
			port, pod.PodName, pod.NodeName)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("[FATAL] Server ListenAndServe error: %v", err)
		}
	}()

	shutdownChan := make(chan os.Signal, 1)
	signal.Notify(shutdownChan, os.Interrupt, syscall.SIGTERM, syscall.SIGINT)

	sig := <-shutdownChan
	log.Printf("[INFO] Signal %v received. Draining connections gracefully...", sig)

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		log.Printf("[ERROR] Forced shutdown: %v", err)
	} else {
		log.Printf("[INFO] Graceful shutdown completed.")
	}
}

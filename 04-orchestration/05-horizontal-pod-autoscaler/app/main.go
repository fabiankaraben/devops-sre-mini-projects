package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"strconv"
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

var (
	startTime          = time.Now()
	totalRequests      uint64
	cpuBurnRequests    uint64
	totalBurnMillis    uint64
)

func getEnv(key, fallback string) string {
	if val, ok := os.LookupEnv(key); ok && val != "" {
		return val
	}
	return fallback
}

// performCPUBurn performs intensive cryptographic SHA256 computations for a given duration or iteration count
func performCPUBurn(duration time.Duration, iterations int) (string, time.Duration) {
	start := time.Now()
	data := []byte("antigravity-devops-sre-autoscale-synthetic-cpu-load-generator")
	hash := sha256.Sum256(data)

	if duration > 0 {
		for time.Since(start) < duration {
			for i := 0; i < 5000; i++ {
				hash = sha256.Sum256(hash[:])
			}
		}
	} else {
		for i := 0; i < iterations; i++ {
			hash = sha256.Sum256(hash[:])
		}
	}

	elapsed := time.Since(start)
	return hex.EncodeToString(hash[:]), elapsed
}

func main() {
	port := getEnv("PORT", "8080")

	hostname, err := os.Hostname()
	if err != nil {
		hostname = "autoscale-app-0"
	}

	pod := PodMetadata{
		PodName:      getEnv("POD_NAME", hostname),
		PodNamespace: getEnv("POD_NAMESPACE", "hpa-demo"),
		PodIP:        getEnv("POD_IP", "127.0.0.1"),
		NodeName:     getEnv("NODE_NAME", "kubernetes-node"),
	}

	mux := http.NewServeMux()

	// GET / - Status and metadata endpoint
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}

		count := atomic.AddUint64(&totalRequests, 1)
		resp := map[string]interface{}{
			"service":             "autoscale-app",
			"message":             "Horizontal Pod Autoscaling (HPA v2) Demo",
			"pod":                 pod,
			"active_goroutines":   runtime.NumGoroutine(),
			"num_cpu":             runtime.NumCPU(),
			"total_requests":      count,
			"cpu_burn_requests":   atomic.LoadUint64(&cpuBurnRequests),
			"uptime_seconds":      time.Since(startTime).Seconds(),
			"timestamp":           time.Now().UTC(),
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(resp)
	})

	// GET /cpu-burn or POST /cpu-burn - Generates deterministic CPU burn
	mux.HandleFunc("/cpu-burn", func(w http.ResponseWriter, r *http.Request) {
		atomic.AddUint64(&totalRequests, 1)
		burnCount := atomic.AddUint64(&cpuBurnRequests, 1)

		// Parse duration or iterations
		durParam := r.URL.Query().Get("duration")
		iterParam := r.URL.Query().Get("iterations")

		burnDuration := 200 * time.Millisecond
		if durParam != "" {
			if d, err := time.ParseDuration(durParam); err == nil && d > 0 && d <= 5*time.Second {
				burnDuration = d
			}
		}

		iterations := 0
		if iterParam != "" {
			if it, err := strconv.Atoi(iterParam); err == nil && it > 0 && it <= 10000000 {
				iterations = it
				burnDuration = 0
			}
		}

		finalHash, elapsed := performCPUBurn(burnDuration, iterations)
		atomic.AddUint64(&totalBurnMillis, uint64(elapsed.Milliseconds()))

		resp := map[string]interface{}{
			"status":            "cpu_burn_completed",
			"pod_name":          pod.PodName,
			"compute_duration":  elapsed.String(),
			"compute_millis":    elapsed.Milliseconds(),
			"sha256_result":     finalHash,
			"burn_request_num":  burnCount,
			"active_goroutines": runtime.NumGoroutine(),
			"timestamp":         time.Now().UTC(),
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(resp)
	})

	// GET /metrics - Prometheus Metrics Endpoint
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		uptime := time.Since(startTime).Seconds()
		reqs := atomic.LoadUint64(&totalRequests)
		burns := atomic.LoadUint64(&cpuBurnRequests)
		burnMillis := atomic.LoadUint64(&totalBurnMillis)

		metrics := fmt.Sprintf(`# HELP http_requests_total Total number of HTTP requests processed.
# TYPE http_requests_total counter
http_requests_total{pod="%s"} %d

# HELP app_cpu_burn_requests_total Total number of synthetic CPU burn operations.
# TYPE app_cpu_burn_requests_total counter
app_cpu_burn_requests_total{pod="%s"} %d

# HELP app_cpu_burn_seconds_total Total duration in seconds spent executing CPU burns.
# TYPE app_cpu_burn_seconds_total counter
app_cpu_burn_seconds_total{pod="%s"} %.3f

# HELP app_goroutines_count Current number of active goroutines.
# TYPE app_goroutines_count gauge
app_goroutines_count{pod="%s"} %d

# HELP app_uptime_seconds Total application uptime in seconds.
# TYPE app_uptime_seconds gauge
app_uptime_seconds{pod="%s"} %.2f
`, pod.PodName, reqs, pod.PodName, burns, pod.PodName, float64(burnMillis)/1000.0, pod.PodName, runtime.NumGoroutine(), pod.PodName, uptime)

		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(metrics))
	})

	// Health Probes
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
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  30 * time.Second,
	}

	go func() {
		log.Printf("[INFO] Autoscaling microservice listening on :%s (Pod: %s, Node: %s, CPU cores: %d)",
			port, pod.PodName, pod.NodeName, runtime.NumCPU())
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
		log.Printf("[INFO] Server stopped gracefully.")
	}
}

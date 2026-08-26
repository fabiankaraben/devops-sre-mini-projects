package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"runtime"
	"sync/atomic"
	"time"
)

// NodeMetrics represents JSON host monitoring data
type NodeMetrics struct {
	AgentVersion   string            `json:"agent_version"`
	PodName        string            `json:"pod_name"`
	NodeName       string            `json:"node_name"`
	HostIP         string            `json:"host_ip"`
	Timestamp      string            `json:"timestamp"`
	OS             string            `json:"os"`
	Architecture   string            `json:"architecture"`
	NumCPU         int               `json:"num_cpu"`
	ScrapeRequests uint64            `json:"scrape_requests"`
	HostMounts     map[string]string `json:"host_mounts"`
}

// HealthResponse represents probe status
type HealthResponse struct {
	Status    string `json:"status"`
	Agent     string `json:"agent"`
	NodeName  string `json:"node_name"`
	Timestamp string `json:"timestamp"`
}

var requestCounter uint64

func getEnv(key, fallback string) string {
	if val, ok := os.LookupEnv(key); ok {
		return val
	}
	return fallback
}

func checkHostMount(path string) string {
	if _, err := os.Stat(path); err == nil {
		return "accessible"
	}
	return "not-mounted"
}

func main() {
	port := getEnv("PORT", "9100")
	agentVersion := getEnv("AGENT_VERSION", "v1.0.0")
	nodeName := getEnv("NODE_NAME", "unknown-node")
	podName := getEnv("POD_NAME", "unknown-pod")
	hostIP := getEnv("HOST_IP", "127.0.0.1")

	log.Printf("[INIT] Starting Node System Agent Daemon (%s) on Node: %s (Port: %s)",
		agentVersion, nodeName, port)

	// Root JSON endpoint
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		atomic.AddUint64(&requestCounter, 1)

		mounts := map[string]string{
			"/host/proc": checkHostMount("/host/proc"),
			"/host/sys":  checkHostMount("/host/sys"),
			"/var/log":   checkHostMount("/var/log"),
		}

		resp := NodeMetrics{
			AgentVersion:   agentVersion,
			PodName:        podName,
			NodeName:       nodeName,
			HostIP:         hostIP,
			Timestamp:      time.Now().UTC().Format(time.RFC3339),
			OS:             runtime.GOOS,
			Architecture:   runtime.GOARCH,
			NumCPU:         runtime.NumCPU(),
			ScrapeRequests: atomic.LoadUint64(&requestCounter),
			HostMounts:     mounts,
		}

		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Node-Name", nodeName)
		w.Header().Set("X-Agent-Version", agentVersion)
		w.WriteHeader(http.StatusOK)

		if err := json.NewEncoder(w).Encode(resp); err != nil {
			log.Printf("[ERROR] Failed to encode JSON response: %v", err)
		}
	})

	// Prometheus Metrics Endpoint
	http.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		atomic.AddUint64(&requestCounter, 1)
		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		w.WriteHeader(http.StatusOK)

		fmt.Fprintf(w, "# HELP node_agent_up Indicates if the node system agent is operational\n")
		fmt.Fprintf(w, "# TYPE node_agent_up gauge\n")
		fmt.Fprintf(w, "node_agent_up{node=\"%s\",version=\"%s\"} 1\n", nodeName, agentVersion)

		fmt.Fprintf(w, "# HELP node_agent_cpus Total CPU cores reported on the node\n")
		fmt.Fprintf(w, "# TYPE node_agent_cpus gauge\n")
		fmt.Fprintf(w, "node_agent_cpus{node=\"%s\"} %d\n", nodeName, runtime.NumCPU())

		fmt.Fprintf(w, "# HELP node_agent_scrapes_total Total HTTP scrape requests served\n")
		fmt.Fprintf(w, "# TYPE node_agent_scrapes_total counter\n")
		fmt.Fprintf(w, "node_agent_scrapes_total{node=\"%s\"} %d\n", nodeName, atomic.LoadUint64(&requestCounter))
	})

	// Health probes
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(HealthResponse{
			Status:    "healthy",
			Agent:     "node-system-agent",
			NodeName:  nodeName,
			Timestamp: time.Now().UTC().Format(time.RFC3339),
		})
	})

	server := &http.Server{
		Addr:         ":" + port,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
	}

	log.Printf("[READY] Node System Agent listening on port :%s", port)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("[FATAL] Server error: %v", err)
	}
}

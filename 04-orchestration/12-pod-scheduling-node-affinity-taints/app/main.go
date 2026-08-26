package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"
)

// WorkloadInfo captures pod and node scheduling metadata
type WorkloadInfo struct {
	PodName       string            `json:"pod_name"`
	PodNamespace  string            `json:"pod_namespace"`
	PodIP         string            `json:"pod_ip"`
	NodeName      string            `json:"node_name"`
	WorkloadType  string            `json:"workload_type"`
	SchedulingTag string            `json:"scheduling_tag"`
	Timestamp     string            `json:"timestamp"`
	EnvVariables  map[string]string `json:"env_variables"`
}

// HealthStatus represents health probe status
type HealthStatus struct {
	Status    string `json:"status"`
	NodeName  string `json:"node_name"`
	Timestamp string `json:"timestamp"`
}

func getEnv(key, fallback string) string {
	if val, ok := os.LookupEnv(key); ok {
		return val
	}
	return fallback
}

func main() {
	port := getEnv("PORT", "8080")
	podName := getEnv("POD_NAME", "unknown-pod")
	podNamespace := getEnv("POD_NAMESPACE", "default")
	podIP := getEnv("POD_IP", "127.0.0.1")
	nodeName := getEnv("NODE_NAME", "unknown-node")
	workloadType := getEnv("WORKLOAD_TYPE", "generic")
	schedulingTag := getEnv("SCHEDULING_TAG", "default")

	log.Printf("[SCHEDULER-APP] Starting Workload Reporter (%s) on Node: %s (Namespace: %s)",
		podName, nodeName, podNamespace)

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		resp := WorkloadInfo{
			PodName:       podName,
			PodNamespace:  podNamespace,
			PodIP:         podIP,
			NodeName:      nodeName,
			WorkloadType:  workloadType,
			SchedulingTag: schedulingTag,
			Timestamp:     time.Now().UTC().Format(time.RFC3339),
			EnvVariables: map[string]string{
				"AFFINITY_POLICY": getEnv("AFFINITY_POLICY", "none"),
				"TAINT_TOLERATED": getEnv("TAINT_TOLERATED", "false"),
				"TOPOLOGY_ZONE":   getEnv("TOPOLOGY_ZONE", "unspecified"),
			},
		}

		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Node-Name", nodeName)
		w.Header().Set("X-Workload-Type", workloadType)
		w.WriteHeader(http.StatusOK)

		if err := json.NewEncoder(w).Encode(resp); err != nil {
			log.Printf("[ERROR] Failed to encode JSON response: %v", err)
		}
	})

	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(HealthStatus{
			Status:    "healthy",
			NodeName:  nodeName,
			Timestamp: time.Now().UTC().Format(time.RFC3339),
		})
	})

	server := &http.Server{
		Addr:         ":" + port,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
	}

	log.Printf("[READY] Workload Reporter listening on port :%s", port)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("[FATAL] Server terminated unexpectedly: %v", err)
	}
}

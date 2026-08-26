package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"runtime"
	"time"
)

// WorkloadStatus represents JSON runtime priority metadata
type WorkloadStatus struct {
	PodName        string            `json:"pod_name"`
	Namespace      string            `json:"namespace"`
	NodeName       string            `json:"node_name"`
	PriorityClass  string            `json:"priority_class"`
	PriorityTier   string            `json:"priority_tier"`
	Timestamp      string            `json:"timestamp"`
	OS             string            `json:"os"`
	Architecture   string            `json:"architecture"`
	NumCPU         int               `json:"num_cpu"`
	AllocatedCPU   string            `json:"allocated_cpu"`
	AllocatedMem   string            `json:"allocated_mem"`
	Environment    map[string]string `json:"environment"`
}

// HealthResponse represents health status
type HealthResponse struct {
	Status        string `json:"status"`
	PriorityClass string `json:"priority_class"`
	Timestamp     string `json:"timestamp"`
}

func getEnv(key, fallback string) string {
	if val, ok := os.LookupEnv(key); ok {
		return val
	}
	return fallback
}

func main() {
	port := getEnv("PORT", "8080")
	podName := getEnv("POD_NAME", "priority-workload-pod")
	namespace := getEnv("POD_NAMESPACE", "default")
	nodeName := getEnv("NODE_NAME", "unknown-node")
	priorityClass := getEnv("PRIORITY_CLASS", "standard-tier")
	priorityTier := getEnv("PRIORITY_TIER", "standard")

	log.Printf("[INIT] Starting Priority Workload Pod [%s] Tier: %s on Node: %s (Port: %s)",
		priorityClass, priorityTier, nodeName, port)

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		resp := WorkloadStatus{
			PodName:       podName,
			Namespace:     namespace,
			NodeName:      nodeName,
			PriorityClass: priorityClass,
			PriorityTier:  priorityTier,
			Timestamp:     time.Now().UTC().Format(time.RFC3339),
			OS:            runtime.GOOS,
			Architecture:  runtime.GOARCH,
			NumCPU:        runtime.NumCPU(),
			AllocatedCPU:  getEnv("RESOURCE_CPU_REQUEST", "50m"),
			AllocatedMem:  getEnv("RESOURCE_MEM_REQUEST", "64Mi"),
			Environment: map[string]string{
				"WORKLOAD_PURPOSE": getEnv("WORKLOAD_PURPOSE", "demonstration"),
			},
		}

		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Priority-Class", priorityClass)
		w.WriteHeader(http.StatusOK)

		if err := json.NewEncoder(w).Encode(resp); err != nil {
			log.Printf("[ERROR] Failed to encode JSON response: %v", err)
		}
	})

	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(HealthResponse{
			Status:        "healthy",
			PriorityClass: priorityClass,
			Timestamp:     time.Now().UTC().Format(time.RFC3339),
		})
	})

	server := &http.Server{
		Addr:         ":" + port,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
	}

	log.Printf("[READY] Workload HTTP Server listening on port :%s", port)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("[FATAL] Server terminated: %v", err)
	}
}

package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"runtime"
	"time"
)

// StaticPodInfo captures runtime diagnostics of a Static Pod
type StaticPodInfo struct {
	PodName       string            `json:"pod_name"`
	NodeName      string            `json:"node_name"`
	PodNamespace  string            `json:"pod_namespace"`
	SupervisedBy  string            `json:"supervised_by"`
	AppVersion    string            `json:"app_version"`
	Timestamp     string            `json:"timestamp"`
	UptimeSeconds int64             `json:"uptime_seconds"`
	NumCPU        int               `json:"num_cpu"`
	OS            string            `json:"os"`
	Architecture  string            `json:"architecture"`
	Environment   map[string]string `json:"environment"`
}

// HealthStatus represents health probe status
type HealthStatus struct {
	Status    string `json:"status"`
	Service   string `json:"service"`
	Timestamp string `json:"timestamp"`
}

var startTime = time.Now()

func getEnv(key, fallback string) string {
	if val, ok := os.LookupEnv(key); ok {
		return val
	}
	return fallback
}

func main() {
	port := getEnv("PORT", "8888")
	podName := getEnv("POD_NAME", "static-diagnostics-pod")
	nodeName := getEnv("NODE_NAME", "unknown-node")
	podNamespace := getEnv("POD_NAMESPACE", "default")
	appVersion := getEnv("APP_VERSION", "v1.0.0")

	log.Printf("[STATIC-POD-INIT] Starting Static Pod Diagnostics Server (%s) on Node: %s (Port: %s)",
		appVersion, nodeName, port)

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		uptime := int64(time.Since(startTime).Seconds())

		resp := StaticPodInfo{
			PodName:       podName,
			NodeName:      nodeName,
			PodNamespace:  podNamespace,
			SupervisedBy:  "Kubelet (Static Pod Manifest)",
			AppVersion:    appVersion,
			Timestamp:     time.Now().UTC().Format(time.RFC3339),
			UptimeSeconds: uptime,
			NumCPU:        runtime.NumCPU(),
			OS:            runtime.GOOS,
			Architecture:  runtime.GOARCH,
			Environment: map[string]string{
				"COMPONENT_TYPE":  getEnv("COMPONENT_TYPE", "control-plane-diagnostics"),
				"MANIFEST_SOURCE": getEnv("MANIFEST_SOURCE", "/etc/kubernetes/manifests"),
			},
		}

		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Supervised-By", "Kubelet-Static-Pod")
		w.Header().Set("X-Node-Name", nodeName)
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
			Service:   "static-diagnostics-web",
			Timestamp: time.Now().UTC().Format(time.RFC3339),
		})
	})

	// Endpoint to simulate process crash to observe Kubelet self-healing
	http.HandleFunc("/simulate-crash", func(w http.ResponseWriter, r *http.Request) {
		log.Printf("[SIMULATION] Crash endpoint called. Process terminating to test Kubelet restart...")
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte("Process terminating. Kubelet will restart the static pod.\n"))
		go func() {
			time.Sleep(100 * time.Millisecond)
			os.Exit(1)
		}()
	})

	server := &http.Server{
		Addr:         ":" + port,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
	}

	log.Printf("[READY] Static Pod Server listening on port :%s", port)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("[FATAL] Server terminated: %v", err)
	}
}

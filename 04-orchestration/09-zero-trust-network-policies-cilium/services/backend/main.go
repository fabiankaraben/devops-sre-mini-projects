package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

type APIResponse struct {
	Service   string    `json:"service"`
	Namespace string    `json:"namespace"`
	PodName   string    `json:"pod_name"`
	PodIP     string    `json:"pod_ip"`
	Status    string    `json:"status"`
	Message   string    `json:"message"`
	Timestamp time.Time `json:"timestamp"`
}

func getEnv(key, fallback string) string {
	if val, ok := os.LookupEnv(key); ok && val != "" {
		return val
	}
	return fallback
}

func main() {
	port := getEnv("PORT", "8080")
	podName := getEnv("POD_NAME", "backend-local")
	podNamespace := getEnv("POD_NAMESPACE", "tenant-backend")
	podIP := getEnv("POD_IP", "127.0.0.1")
	dbHost := getEnv("DB_HOST", "database.tenant-database.svc.cluster.local:5432")

	mux := http.NewServeMux()

	// POST /api - Authorized business API endpoint
	mux.HandleFunc("/api", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "Method Not Allowed (Only POST is authorized by Zero-Trust policy)", http.StatusMethodNotAllowed)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Zero-Trust-Tier", "backend")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(APIResponse{
			Service:   "backend-api",
			Namespace: podNamespace,
			PodName:   podName,
			PodIP:     podIP,
			Status:    "success",
			Message:   "Authorized transaction processed via L7 policy",
			Timestamp: time.Now().UTC(),
		})
	})

	// GET /admin - Unauthorized path for testing L7 path filtering
	mux.HandleFunc("/admin", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusForbidden)
		_ = json.NewEncoder(w).Encode(APIResponse{
			Service:   "backend-api",
			Namespace: podNamespace,
			PodName:   podName,
			PodIP:     podIP,
			Status:    "forbidden",
			Message:   "Access to /admin is restricted by Zero-Trust L7 policy",
			Timestamp: time.Now().UTC(),
		})
	})

	// GET /query-db - Connects to Database over TCP 5432
	mux.HandleFunc("/query-db", func(w http.ResponseWriter, r *http.Request) {
		conn, err := net.DialTimeout("tcp", dbHost, 2*time.Second)
		if err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusServiceUnavailable)
			_ = json.NewEncoder(w).Encode(map[string]interface{}{
				"status":  "error",
				"target":  dbHost,
				"message": fmt.Sprintf("Database connection failed: %v", err),
			})
			return
		}
		defer conn.Close()

		buf := make([]byte, 128)
		_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		n, _ := conn.Read(buf)

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"status":      "connected",
			"target":      dbHost,
			"db_response": string(buf[:n]),
			"message":     "TCP 5432 connection successfully established to database",
		})
	})

	// Health probes
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "alive", "service": "backend"})
	})

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(APIResponse{
			Service:   "backend-api",
			Namespace: podNamespace,
			PodName:   podName,
			PodIP:     podIP,
			Status:    "healthy",
			Message:   "Zero-Trust Backend Microservice is active",
			Timestamp: time.Now().UTC(),
		})
	})

	server := &http.Server{
		Addr:         ":" + port,
		Handler:      mux,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
	}

	go func() {
		log.Printf("[BACKEND] Listening on port :%s (Namespace: %s)", port, podNamespace)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("[FATAL] Server error: %v", err)
		}
	}()

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)
	<-sigChan

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = server.Shutdown(ctx)
}

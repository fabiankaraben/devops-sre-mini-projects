package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

type FrontendResponse struct {
	Service   string      `json:"service"`
	Namespace string      `json:"namespace"`
	PodName   string      `json:"pod_name"`
	Action    string      `json:"action"`
	Target    string      `json:"target"`
	Status    string      `json:"status"`
	Details   interface{} `json:"details"`
	Timestamp time.Time   `json:"timestamp"`
}

func getEnv(key, fallback string) string {
	if val, ok := os.LookupEnv(key); ok && val != "" {
		return val
	}
	return fallback
}

func main() {
	port := getEnv("PORT", "8080")
	podName := getEnv("POD_NAME", "frontend-local")
	podNamespace := getEnv("POD_NAMESPACE", "tenant-frontend")
	backendURL := getEnv("BACKEND_URL", "http://backend.tenant-backend.svc.cluster.local:8080")
	dbHost := getEnv("DB_HOST", "database.tenant-database.svc.cluster.local:5432")

	client := &http.Client{Timeout: 3 * time.Second}
	mux := http.NewServeMux()

	// POST /send-order -> Calls Backend POST /api (Authorized L7 path)
	mux.HandleFunc("/send-order", func(w http.ResponseWriter, r *http.Request) {
		target := backendURL + "/api"
		req, _ := http.NewRequest(http.MethodPost, target, strings.NewReader(`{"order_id": "ORD-12345"}`))
		req.Header.Set("Content-Type", "application/json")

		resp, err := client.Do(req)
		if err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadGateway)
			_ = json.NewEncoder(w).Encode(FrontendResponse{
				Service:   "frontend-proxy",
				Namespace: podNamespace,
				PodName:   podName,
				Action:    "POST /api",
				Target:    target,
				Status:    "error",
				Details:   fmt.Sprintf("Failed to contact backend: %v", err),
				Timestamp: time.Now().UTC(),
			})
			return
		}
		defer resp.Body.Close()

		body, _ := io.ReadAll(resp.Body)
		var parsed map[string]interface{}
		_ = json.Unmarshal(body, &parsed)

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(resp.StatusCode)
		_ = json.NewEncoder(w).Encode(FrontendResponse{
			Service:   "frontend-proxy",
			Namespace: podNamespace,
			PodName:   podName,
			Action:    "POST /api",
			Target:    target,
			Status:    "success",
			Details:   parsed,
			Timestamp: time.Now().UTC(),
		})
	})

	// GET /try-admin -> Calls Backend GET /admin (Blocked by L7 policy)
	mux.HandleFunc("/try-admin", func(w http.ResponseWriter, r *http.Request) {
		target := backendURL + "/admin"
		resp, err := client.Get(target)
		if err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadGateway)
			_ = json.NewEncoder(w).Encode(FrontendResponse{
				Service:   "frontend-proxy",
				Namespace: podNamespace,
				PodName:   podName,
				Action:    "GET /admin",
				Target:    target,
				Status:    "blocked_or_error",
				Details:   fmt.Sprintf("Network connection dropped or rejected: %v", err),
				Timestamp: time.Now().UTC(),
			})
			return
		}
		defer resp.Body.Close()

		body, _ := io.ReadAll(resp.Body)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(resp.StatusCode)
		_ = json.NewEncoder(w).Encode(FrontendResponse{
			Service:   "frontend-proxy",
			Namespace: podNamespace,
			PodName:   podName,
			Action:    "GET /admin",
			Target:    target,
			Status:    "response_received",
			Details:   string(body),
			Timestamp: time.Now().UTC(),
		})
	})

	// GET /try-database -> Direct connection to Database (Blocked by L4 default-deny)
	mux.HandleFunc("/try-database", func(w http.ResponseWriter, r *http.Request) {
		conn, err := net.DialTimeout("tcp", dbHost, 2*time.Second)
		if err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusForbidden)
			_ = json.NewEncoder(w).Encode(FrontendResponse{
				Service:   "frontend-proxy",
				Namespace: podNamespace,
				PodName:   podName,
				Action:    "TCP Connect 5432",
				Target:    dbHost,
				Status:    "blocked_by_policy",
				Details:   fmt.Sprintf("Direct access from Frontend to Database was dropped by Zero-Trust policy: %v", err),
				Timestamp: time.Now().UTC(),
			})
			return
		}
		defer conn.Close()

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(FrontendResponse{
			Service:   "frontend-proxy",
			Namespace: podNamespace,
			PodName:   podName,
			Action:    "TCP Connect 5432",
			Target:    dbHost,
			Status:    "unexpected_success",
			Details:   "Direct connection established (Warning: Policy not active)",
			Timestamp: time.Now().UTC(),
		})
	})

	// Health probes
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "alive", "service": "frontend"})
	})

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(FrontendResponse{
			Service:   "frontend-tier",
			Namespace: podNamespace,
			PodName:   podName,
			Action:    "Status",
			Target:    "self",
			Status:    "healthy",
			Details:   "Zero-Trust Frontend Microservice ready for traffic",
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
		log.Printf("[FRONTEND] Listening on port :%s (Namespace: %s)", port, podNamespace)
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

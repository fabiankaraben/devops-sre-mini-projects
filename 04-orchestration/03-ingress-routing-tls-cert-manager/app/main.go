package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"strings"
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

type APIResponse struct {
	Service       string            `json:"service"`
	Message       string            `json:"message"`
	Version       string            `json:"version"`
	Pod           PodMetadata       `json:"pod"`
	Request       RequestMetadata   `json:"request"`
	Timestamp     time.Time         `json:"timestamp"`
	UptimeSeconds float64           `json:"uptime_seconds"`
	RequestCount  uint64            `json:"request_count"`
}

type RequestMetadata struct {
	Host           string            `json:"host"`
	Method         string            `json:"method"`
	URL            string            `json:"url"`
	Protocol       string            `json:"protocol"`
	ForwardedProto string            `json:"forwarded_proto"`
	ForwardedFor   string            `json:"forwarded_for"`
	Headers        map[string]string `json:"headers"`
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

func extractRequestMeta(r *http.Request) RequestMetadata {
	headers := make(map[string]string)
	for k, v := range r.Header {
		if len(v) > 0 {
			headers[k] = v[0]
		}
	}

	proto := "http"
	if r.TLS != nil || r.Header.Get("X-Forwarded-Proto") == "https" {
		proto = "https"
	}

	return RequestMetadata{
		Host:           r.Host,
		Method:         r.Method,
		URL:            r.URL.String(),
		Protocol:       proto,
		ForwardedProto: r.Header.Get("X-Forwarded-Proto"),
		ForwardedFor:   r.Header.Get("X-Forwarded-For"),
		Headers:        headers,
	}
}

func renderHTMLDashboard(w http.ResponseWriter, r *http.Request, pod PodMetadata, count uint64) {
	reqMeta := extractRequestMeta(r)
	uptime := time.Since(startTime).Seconds()

	html := fmt.Sprintf(`<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Web Frontend - Ingress & TLS Demo</title>
    <style>
        :root {
            --bg: #0d1117;
            --card-bg: #161b22;
            --border: #30363d;
            --text: #c9d1d9;
            --heading: #58a6ff;
            --accent: #2ea043;
            --badge-bg: #21262d;
        }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            background: var(--bg);
            color: var(--text);
            margin: 0;
            padding: 2rem;
            display: flex;
            justify-content: center;
        }
        .container {
            max-width: 800px;
            width: 100%%;
        }
        .card {
            background: var(--card-bg);
            border: 1px solid var(--border);
            border-radius: 12px;
            padding: 2rem;
            box-shadow: 0 8px 24px rgba(0,0,0,0.4);
            margin-bottom: 1.5rem;
        }
        h1 { color: var(--heading); margin-top: 0; }
        .badge {
            display: inline-block;
            padding: 0.25rem 0.75rem;
            border-radius: 20px;
            font-size: 0.85rem;
            font-weight: 600;
            background: var(--badge-bg);
            border: 1px solid var(--border);
            margin-right: 0.5rem;
        }
        .badge-tls { color: #3fb950; border-color: #238636; }
        .badge-host { color: #58a6ff; border-color: #1f6feb; }
        .grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
            gap: 1rem;
            margin-top: 1.5rem;
        }
        .stat-box {
            background: var(--badge-bg);
            padding: 1rem;
            border-radius: 8px;
            border: 1px solid var(--border);
        }
        .stat-label { font-size: 0.8rem; color: #8b949e; text-transform: uppercase; }
        .stat-value { font-size: 1.1rem; font-weight: bold; margin-top: 0.25rem; word-break: break-all; }
        .footer { text-align: center; color: #8b949e; font-size: 0.85rem; margin-top: 2rem; }
    </style>
</head>
<body>
    <div class="container">
        <div class="card">
            <h1>🌐 Web Frontend Service</h1>
            <p>Traffic routed seamlessly via Kubernetes Ingress Controller with automated TLS termination.</p>
            <div>
                <span class="badge badge-tls">🔒 TLS: %s</span>
                <span class="badge badge-host">📍 Host: %s</span>
                <span class="badge">🚀 Node: %s</span>
            </div>
            <div class="grid">
                <div class="stat-box">
                    <div class="stat-label">Pod Name</div>
                    <div class="stat-value">%s</div>
                </div>
                <div class="stat-box">
                    <div class="stat-label">Pod IP</div>
                    <div class="stat-value">%s</div>
                </div>
                <div class="stat-box">
                    <div class="stat-label">Namespace</div>
                    <div class="stat-value">%s</div>
                </div>
                <div class="stat-box">
                    <div class="stat-label">Requests Served</div>
                    <div class="stat-value">%d</div>
                </div>
                <div class="stat-box">
                    <div class="stat-label">Uptime</div>
                    <div class="stat-value">%.1fs</div>
                </div>
                <div class="stat-box">
                    <div class="stat-label">Protocol</div>
                    <div class="stat-value">%s</div>
                </div>
            </div>
        </div>
        <div class="footer">
            DevOps SRE Mini-Projects &bull; 04. Kubernetes Ingress & TLS with cert-manager
        </div>
    </div>
</body>
</html>`, reqMeta.Protocol, reqMeta.Host, pod.NodeName, pod.PodName, pod.PodIP, pod.PodNamespace, count, uptime, reqMeta.Protocol)

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(html))
}

func main() {
	serviceType := strings.ToLower(getEnv("SERVICE_TYPE", "web"))
	port := getEnv("PORT", "8080")

	hostname, err := os.Hostname()
	if err != nil {
		hostname = "unknown-host"
	}

	pod := PodMetadata{
		PodName:      getEnv("POD_NAME", hostname),
		PodNamespace: getEnv("POD_NAMESPACE", "ingress-tls-demo"),
		PodIP:        getEnv("POD_IP", "127.0.0.1"),
		NodeName:     getEnv("NODE_NAME", "kubernetes-node"),
	}

	mux := http.NewServeMux()

	// Root Handler
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		count := atomic.AddUint64(&requestCount, 1)

		// If service is "web" and client accepts HTML, render dashboard
		acceptHeader := r.Header.Get("Accept")
		if serviceType == "web" && strings.Contains(acceptHeader, "text/html") && r.URL.Query().Get("format") != "json" {
			renderHTMLDashboard(w, r, pod, count)
			return
		}

		// Otherwise, render JSON response
		reqMeta := extractRequestMeta(r)
		resp := APIResponse{
			Service:       serviceType + "-backend",
			Message:       fmt.Sprintf("Hello from %s service on Kubernetes!", serviceType),
			Version:       "v1.0.0",
			Pod:           pod,
			Request:       reqMeta,
			Timestamp:     time.Now().UTC(),
			UptimeSeconds: time.Since(startTime).Seconds(),
			RequestCount:  count,
		}

		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Service-Type", serviceType)
		w.Header().Set("X-Pod-Name", pod.PodName)
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(resp)
	})

	// Dedicated API Status Handler
	mux.HandleFunc("/api/v1/status", func(w http.ResponseWriter, r *http.Request) {
		count := atomic.AddUint64(&requestCount, 1)
		reqMeta := extractRequestMeta(r)

		resp := map[string]interface{}{
			"status":        "operational",
			"service_type":  serviceType,
			"pod":           pod,
			"request":       reqMeta,
			"timestamp":     time.Now().UTC(),
			"request_count": count,
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(resp)
	})

	// Health Probes
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "alive", "service": serviceType, "pod": pod.PodName})
	})

	mux.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "ready", "service": serviceType, "pod": pod.PodName})
	})

	server := &http.Server{
		Addr:         ":" + port,
		Handler:      mux,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  30 * time.Second,
	}

	go func() {
		log.Printf("[INFO] %s service listening on :%s (Pod: %s, Node: %s, Go: %s)",
			strings.ToUpper(serviceType), port, pod.PodName, pod.NodeName, runtime.Version())
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

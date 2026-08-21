package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"runtime"
	"time"
)

var startTime = time.Now()

type Response struct {
	Service       string                 `json:"service"`
	Version       string                 `json:"version"`
	UptimeSeconds float64                `json:"uptime_seconds"`
	Runtime       RuntimeInfo            `json:"runtime"`
	Security      SecurityInfo           `json:"security"`
	Endpoints     map[string]string      `json:"endpoints"`
}

type RuntimeInfo struct {
	OS           string `json:"os"`
	Architecture string `json:"architecture"`
	GoVersion    string `json:"go_version"`
	NumCPU       int    `json:"num_cpu"`
	PID          int    `json:"pid"`
}

type SecurityInfo struct {
	UID              int  `json:"uid"`
	GID              int  `json:"gid"`
	IsNonRoot        bool `json:"is_non_root"`
	ShellEradicated  bool `json:"shell_eradicated"`
	DistrolessBase   bool `json:"distroless_base"`
}

func getSecurityInfo() SecurityInfo {
	uid := os.Getuid()
	gid := os.Getgid()
	return SecurityInfo{
		UID:             uid,
		GID:             gid,
		IsNonRoot:       uid != 0,
		ShellEradicated: true,
		DistrolessBase:  true,
	}
}

func handleRoot(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")

	resp := Response{
		Service:       "distroless-hardened-runtime-demo",
		Version:       "1.0.0",
		UptimeSeconds: time.Since(startTime).Seconds(),
		Runtime: RuntimeInfo{
			OS:           runtime.GOOS,
			Architecture: runtime.GOARCH,
			GoVersion:    runtime.Version(),
			NumCPU:       runtime.NumCPU(),
			PID:          os.Getpid(),
		},
		Security: getSecurityInfo(),
		Endpoints: map[string]string{
			"root":     "GET /",
			"health":   "GET /health",
			"security": "GET /security",
		},
	}

	json.NewEncoder(w).Encode(resp)
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":         "healthy",
		"uptime_seconds": time.Since(startTime).Seconds(),
	})
}

func handleSecurity(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	json.NewEncoder(w).Encode(getSecurityInfo())
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", handleRoot)
	mux.HandleFunc("/health", handleHealth)
	mux.HandleFunc("/security", handleSecurity)

	addr := fmt.Sprintf(":%s", port)
	log.Printf("🛡️ Distroless Hardened Service listening on port %s (UID: %d, GID: %d)\n", port, os.Getuid(), os.Getgid())
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("Server error: %v", err)
	}
}

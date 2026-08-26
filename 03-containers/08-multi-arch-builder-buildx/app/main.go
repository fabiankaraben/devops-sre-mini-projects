package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"runtime"
	"time"
)

var startTime = time.Now()

type TelemetryResponse struct {
	Status        string  `json:"status"`
	Architecture  string  `json:"architecture"`
	OperatingSys  string  `json:"operating_system"`
	NumCPU        int     `json:"num_cpu"`
	GoVersion     string  `json:"go_version"`
	Hostname      string  `json:"hostname"`
	UptimeSeconds float64 `json:"uptime_seconds"`
}

func getTelemetry() TelemetryResponse {
	hostname, _ := os.Hostname()
	return TelemetryResponse{
		Status:        "UP",
		Architecture:  runtime.GOARCH,
		OperatingSys:  runtime.GOOS,
		NumCPU:        runtime.NumCPU(),
		GoVersion:     runtime.Version(),
		Hostname:      hostname,
		UptimeSeconds: time.Since(startTime).Seconds(),
	}
}

func handleRoot(w http.ResponseWriter, r *http.Request) {
	telemetry := getTelemetry()
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Architecture", runtime.GOARCH)
	json.NewEncoder(w).Encode(telemetry)
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{
		"status": "HEALTHY",
		"arch":   runtime.GOARCH,
	})
}

func main() {
	cliMode := flag.Bool("cli", false, "Execute in CLI mode and print architecture JSON to stdout")
	flag.Parse()

	if *cliMode {
		telemetry := getTelemetry()
		out, _ := json.MarshalIndent(telemetry, "", "  ")
		fmt.Println(string(out))
		os.Exit(0)
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	http.HandleFunc("/", handleRoot)
	http.HandleFunc("/arch", handleRoot)
	http.HandleFunc("/health", handleHealth)

	log.Printf("🚀 Multi-Arch Microservice starting on :%s (Arch: %s, OS: %s, CPUs: %d)",
		port, runtime.GOARCH, runtime.GOOS, runtime.NumCPU())

	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}

package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"
)

// StructuredLog represents a production JSON log event
type StructuredLog struct {
	Timestamp string  `json:"timestamp"`
	Level     string  `json:"level"`
	Service   string  `json:"service"`
	Event     string  `json:"event"`
	OrderID   string  `json:"order_id,omitempty"`
	Amount    float64 `json:"amount,omitempty"`
	Currency  string  `json:"currency,omitempty"`
	UserEmail string  `json:"user_email,omitempty"`
	ClientIP  string  `json:"client_ip,omitempty"`
	APIToken  string  `json:"api_token,omitempty"`
	Message   string  `json:"message,omitempty"`
}

func getEnv(key, fallback string) string {
	if val, ok := os.LookupEnv(key); ok {
		return val
	}
	return fallback
}

func emitLogs(interval time.Duration) {
	ticker := time.NewTicker(interval)
	counter := 0

	for range ticker.C {
		counter++
		now := time.Now().UTC().Format(time.RFC3339)

		// 1. Emit standard structured JSON info log
		infoLog := StructuredLog{
			Timestamp: now,
			Level:     "info",
			Service:   "payment-service",
			Event:     "payment_processed",
			OrderID:   fmt.Sprintf("ord-%05d", counter),
			Amount:    49.99 + float64(counter%10)*5.0,
			Currency:  "USD",
			Message:   "Payment captured successfully via gateway",
		}
		data, _ := json.Marshal(infoLog)
		fmt.Println(string(data))

		// 2. Emit log with simulated secret to test redaction filters
		if counter%2 == 0 {
			warnLog := StructuredLog{
				Timestamp: now,
				Level:     "warn",
				Service:   "auth-gateway",
				Event:     "user_authentication_failed",
				UserEmail: fmt.Sprintf("user-%d@enterprise.internal", counter),
				ClientIP:  "10.244.1.45",
				APIToken:  "sk_live_secret_token_abcdef123456789",
				Message:   "Invalid API token presented during OAuth handshake",
			}
			warnData, _ := json.Marshal(warnLog)
			fmt.Println(string(warnData))
		}

		// 3. Emit multi-line error stack trace
		if counter%3 == 0 {
			fmt.Printf("%s [ERROR] [checkout-api] Database transaction deadlock detected\n", now)
			fmt.Println("goroutine 42 [running]:")
			fmt.Println("github.com/fabiankaraben/payment-service/db.CommitTx(0xc0000a2000)")
			fmt.Println("    /src/db/transaction.go:142 +0x2e8")
			fmt.Println("github.com/fabiankaraben/payment-service/api.HandleCheckout(0xc0000b4000)")
			fmt.Println("    /src/api/checkout.go:87 +0x11a")
		}
	}
}

func main() {
	port := getEnv("PORT", "8080")
	intervalMsStr := getEnv("LOG_INTERVAL_MS", "2000")
	intervalMs, err := strconv.Atoi(intervalMsStr)
	if err != nil || intervalMs < 100 {
		intervalMs = 2000
	}

	log.Printf("[INIT] Starting Log Generator Application (Emitting logs every %dms)...", intervalMs)

	// Start background log generator
	go emitLogs(time.Duration(intervalMs) * time.Millisecond)

	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"healthy","service":"log-generator-app"}`))
	})

	server := &http.Server{
		Addr:         ":" + port,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
	}

	log.Printf("[READY] Health endpoint listening on port :%s", port)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("[FATAL] Server error: %v", err)
	}
}

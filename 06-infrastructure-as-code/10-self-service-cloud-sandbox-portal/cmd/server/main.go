package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/fabiankaraben/devops-sre-mini-projects/06-infrastructure-as-code/10-self-service-cloud-sandbox-portal/pkg/portal"
)

func main() {
	port := flag.Int("port", 8080, "HTTP server listening port")
	baseDir := flag.String("base-dir", ".", "Base directory for portal data, workspaces, and logs")
	ttlInterval := flag.Duration("ttl-interval", 1*time.Second, "TTL check interval for background worker")
	flag.Parse()

	// Handle environment variable override for PORT
	if envPort := os.Getenv("PORT"); envPort != "" {
		fmt.Sscanf(envPort, "%d", port)
	}

	absBase, err := filepath.Abs(*baseDir)
	if err != nil {
		log.Fatalf("Failed to resolve base directory: %v", err)
	}

	dataDir := filepath.Join(absBase, "data")
	dataFile := filepath.Join(dataDir, "sandboxes.json")
	workspacesDir := filepath.Join(absBase, "workspaces")
	templatesDir := filepath.Join(absBase, "templates")
	logsDir := filepath.Join(absBase, "logs")

	log.Println("======================================================================")
	log.Println("  🚀 Starting Self-Service Cloud Sandbox Provisioning Portal")
	log.Println("======================================================================")
	log.Printf("  Port:          %d", *port)
	log.Printf("  Data File:     %s", dataFile)
	log.Printf("  Templates Dir: %s", templatesDir)
	log.Printf("  Workspaces:    %s", workspacesDir)
	log.Printf("  Logs Dir:      %s", logsDir)
	log.Printf("  TTL Check:     %v", *ttlInterval)
	log.Println("======================================================================")

	// 1. Initialize Store
	store, err := portal.NewStore(dataFile)
	if err != nil {
		log.Fatalf("Failed to initialize store: %v", err)
	}

	// 2. Initialize Engine
	engine, err := portal.NewEngine(templatesDir, workspacesDir, logsDir)
	if err != nil {
		log.Fatalf("Failed to initialize IaC engine: %v", err)
	}

	// 3. Initialize & Start Worker
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	worker := portal.NewWorker(store, engine, *ttlInterval)
	worker.Start(ctx)
	defer worker.Stop()

	// 4. Initialize HTTP Server
	server := portal.NewServer(store, engine, worker)
	httpServer := &http.Server{
		Addr:         fmt.Sprintf(":%d", *port),
		Handler:      server,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 15 * time.Minute, // Allow long-running Terraform apply
	}

	// Graceful shutdown channel
	stopCh := make(chan os.Signal, 1)
	signal.Notify(stopCh, os.Interrupt, syscall.SIGTERM)

	go func() {
		log.Printf("  🌐 Server listening on http://127.0.0.1:%d", *port)
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("HTTP server error: %v", err)
		}
	}()

	<-stopCh
	log.Println("\n[Server] Shutdown signal received. Gracefully draining connections...")

	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer shutdownCancel()

	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		log.Printf("[Server] Error during server shutdown: %v", err)
	}

	log.Println("[Server] Server stopped cleanly.")
}

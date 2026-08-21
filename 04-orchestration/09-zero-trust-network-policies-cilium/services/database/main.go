package main

import (
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func getEnv(key, fallback string) string {
	if val, ok := os.LookupEnv(key); ok && val != "" {
		return val
	}
	return fallback
}

func handleConnection(conn net.Conn) {
	defer conn.Close()
	remoteAddr := conn.RemoteAddr().String()
	log.Printf("[DATABASE] New connection established from %s", remoteAddr)

	welcome := fmt.Sprintf("ZERO_TRUST_DATABASE_V16_READY [Client: %s] [Time: %s]\n", remoteAddr, time.Now().UTC().Format(time.RFC3339))
	_, _ = conn.Write([]byte(welcome))

	buf := make([]byte, 256)
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	n, _ := conn.Read(buf)
	if n > 0 {
		log.Printf("[DATABASE] Query received from %s: %s", remoteAddr, string(buf[:n]))
		_, _ = conn.Write([]byte("OK: QUERY_PROCESSED\n"))
	}
}

func main() {
	port := getEnv("PORT", "5432")
	podNamespace := getEnv("POD_NAMESPACE", "tenant-database")

	listener, err := net.Listen("tcp", ":"+port)
	if err != nil {
		log.Fatalf("[FATAL] Database failed to listen on port %s: %v", port, err)
	}
	defer listener.Close()

	log.Printf("[DATABASE] Relational Data Store listening on TCP :%s (Namespace: %s)", port, podNamespace)

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)

	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go handleConnection(conn)
		}
	}()

	<-sigChan
	log.Println("[DATABASE] Shutting down database listener...")
}

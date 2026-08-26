package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"
)

type Record struct {
	ID        int    `json:"id"`
	Timestamp string `json:"timestamp"`
	Message   string `json:"message"`
	Checksum  string `json:"checksum"`
}

type StorageStatus struct {
	Service       string   `json:"service"`
	DataDir       string   `json:"data_dir"`
	TotalRecords  int      `json:"total_records"`
	LastRecord    *Record  `json:"last_record,omitempty"`
	FileSizeBytes int64    `json:"file_size_bytes"`
	Status        string   `json:"status"`
}

var (
	dataMu  sync.Mutex
	dataDir string
	logFile string
)

func getEnv(key, fallback string) string {
	if val, ok := os.LookupEnv(key); ok {
		return val
	}
	return fallback
}

func calculateChecksum(data string) string {
	h := sha256.Sum256([]byte(data))
	return hex.EncodeToString(h[:8])
}

func readRecords() ([]Record, error) {
	dataMu.Lock()
	defer dataMu.Unlock()

	if _, err := os.Stat(logFile); os.IsNotExist(err) {
		return []Record{}, nil
	}

	file, err := os.Open(logFile)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	var records []Record
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		if len(line) == 0 {
			continue
		}
		var r Record
		if err := json.Unmarshal([]byte(line), &r); err == nil {
			records = append(records, r)
		}
	}
	return records, scanner.Err()
}

func appendRecord(msg string) (*Record, error) {
	dataMu.Lock()
	defer dataMu.Unlock()

	_ = os.MkdirAll(dataDir, 0755)

	records, _ := readRecordsUnsafe()
	nextID := len(records) + 1
	now := time.Now().UTC().Format(time.RFC3339)
	rec := Record{
		ID:        nextID,
		Timestamp: now,
		Message:   msg,
		Checksum:  calculateChecksum(fmt.Sprintf("%d-%s-%s", nextID, now, msg)),
	}

	bytes, err := json.Marshal(rec)
	if err != nil {
		return nil, err
	}

	f, err := os.OpenFile(logFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	if _, err := f.WriteString(string(bytes) + "\n"); err != nil {
		return nil, err
	}
	_ = f.Sync() // Force fsync to disk

	return &rec, nil
}

func readRecordsUnsafe() ([]Record, error) {
	if _, err := os.Stat(logFile); os.IsNotExist(err) {
		return []Record{}, nil
	}
	file, err := os.Open(logFile)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	var records []Record
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		var r Record
		if err := json.Unmarshal([]byte(line), &r); err == nil {
			records = append(records, r)
		}
	}
	return records, scanner.Err()
}

func main() {
	port := getEnv("PORT", "8080")
	dataDir = getEnv("DATA_DIR", "/data")
	logFile = filepath.Join(dataDir, "records.log")

	log.Printf("[INIT] Starting Stateful Data Storage App on Port :%s (Storage: %s)", port, logFile)

	_ = os.MkdirAll(dataDir, 0755)

	// Write initial bootstrap record if storage is brand new
	existing, _ := readRecords()
	if len(existing) == 0 {
		_, _ = appendRecord("System Volume Initialized (Bootstrap Record)")
	}

	// Status endpoint
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		records, _ := readRecords()
		var last *Record
		if len(records) > 0 {
			last = &records[len(records)-1]
		}

		var size int64
		if fi, err := os.Stat(logFile); err == nil {
			size = fi.Size()
		}

		resp := StorageStatus{
			Service:       "data-state-app",
			DataDir:       dataDir,
			TotalRecords:  len(records),
			LastRecord:    last,
			FileSizeBytes: size,
			Status:        "operational",
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(resp)
	})

	// Append record endpoint
	http.HandleFunc("/write", func(w http.ResponseWriter, r *http.Request) {
		msg := r.URL.Query().Get("msg")
		if msg == "" {
			msg = fmt.Sprintf("Transaction Event at %s", time.Now().UTC().Format(time.RFC3339))
		}

		rec, err := appendRecord(msg)
		if err != nil {
			http.Error(w, fmt.Sprintf("Failed to write to disk: %v", err), http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(rec)
	})

	// Read all records endpoint
	http.HandleFunc("/records", func(w http.ResponseWriter, r *http.Request) {
		records, err := readRecords()
		if err != nil {
			http.Error(w, fmt.Sprintf("Failed to read disk records: %v", err), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(records)
	})

	// Simulate data corruption
	http.HandleFunc("/corrupt", func(w http.ResponseWriter, r *http.Request) {
		dataMu.Lock()
		defer dataMu.Unlock()
		_ = os.WriteFile(logFile, []byte("CORRUPTED DATA - DISASTER SIMULATION\n"), 0644)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"data_corrupted","action":"ready_for_snapshot_restore"}`))
	})

	// Health check
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"healthy","storage":"connected"}`))
	})

	server := &http.Server{
		Addr:         ":" + port,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
	}

	log.Printf("[READY] Stateful storage server listening on port :%s", port)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("[FATAL] Server error: %v", err)
	}
}

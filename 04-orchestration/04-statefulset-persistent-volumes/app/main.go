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
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type PodMetadata struct {
	PodName      string `json:"pod_name"`
	PodNamespace string `json:"pod_namespace"`
	PodIP        string `json:"pod_ip"`
	NodeName     string `json:"node_name"`
	OrdinalIndex int    `json:"ordinal_index"`
}

type VolumeStats struct {
	MountPath      string  `json:"mount_path"`
	TotalBytes     uint64  `json:"total_bytes"`
	FreeBytes      uint64  `json:"free_bytes"`
	UsedBytes      uint64  `json:"used_bytes"`
	UsagePercent   float64 `json:"usage_percent"`
	RecordCount    int     `json:"record_count"`
	FileSizeBytes  int64   `json:"file_size_bytes"`
	LastModifiedAt string  `json:"last_modified_at"`
}

type StorePayload struct {
	Key       string    `json:"key"`
	Value     string    `json:"value"`
	WriterPod string    `json:"writer_pod"`
	UpdatedAt time.Time `json:"updated_at"`
}

type DataStore struct {
	sync.RWMutex
	filePath string
	records  map[string]StorePayload
}

func newDataStore(filePath string) (*DataStore, error) {
	dir := filepath.Dir(filePath)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create data dir: %w", err)
	}

	ds := &DataStore{
		filePath: filePath,
		records:  make(map[string]StorePayload),
	}

	// Load existing records from disk if file exists
	if data, err := os.ReadFile(filePath); err == nil {
		var loaded map[string]StorePayload
		if err := json.Unmarshal(data, &loaded); err == nil {
			ds.records = loaded
			log.Printf("[INFO] Loaded %d persisted records from %s", len(ds.records), filePath)
		}
	} else if !os.IsNotExist(err) {
		return nil, fmt.Errorf("failed to read store file: %w", err)
	}

	return ds, nil
}

func (ds *DataStore) set(key, value, podName string) (StorePayload, error) {
	ds.Lock()
	defer ds.Unlock()

	item := StorePayload{
		Key:       key,
		Value:     value,
		WriterPod: podName,
		UpdatedAt: time.Now().UTC(),
	}
	ds.records[key] = item

	// Persist to disk atomically
	data, err := json.MarshalIndent(ds.records, "", "  ")
	if err != nil {
		return item, fmt.Errorf("failed to marshal records: %w", err)
	}

	tmpPath := ds.filePath + ".tmp"
	if err := os.WriteFile(tmpPath, data, 0644); err != nil {
		return item, fmt.Errorf("failed to write tmp file: %w", err)
	}

	if err := os.Rename(tmpPath, ds.filePath); err != nil {
		return item, fmt.Errorf("failed to rename file: %w", err)
	}

	return item, nil
}

func (ds *DataStore) getAll() map[string]StorePayload {
	ds.RLock()
	defer ds.RUnlock()

	copyMap := make(map[string]StorePayload, len(ds.records))
	for k, v := range ds.records {
		copyMap[k] = v
	}
	return copyMap
}

func (ds *DataStore) get(key string) (StorePayload, bool) {
	ds.RLock()
	defer ds.RUnlock()

	item, exists := ds.records[key]
	return item, exists
}

func getEnv(key, fallback string) string {
	if val, ok := os.LookupEnv(key); ok && val != "" {
		return val
	}
	return fallback
}

func extractOrdinal(podName string) int {
	parts := strings.Split(podName, "-")
	if len(parts) > 0 {
		if ord, err := strconv.Atoi(parts[len(parts)-1]); err == nil {
			return ord
		}
	}
	return -1
}

func getDiskStats(path string) (uint64, uint64, uint64, float64) {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(path, &stat); err != nil {
		return 0, 0, 0, 0
	}

	total := stat.Blocks * uint64(stat.Bsize)
	free := stat.Bavail * uint64(stat.Bsize)
	used := total - free
	usagePct := 0.0
	if total > 0 {
		usagePct = float64(used) / float64(total) * 100.0
	}
	return total, free, used, usagePct
}

func main() {
	port := getEnv("PORT", "8080")
	dataDir := getEnv("DATA_DIR", "/data")
	storeFile := filepath.Join(dataDir, "store.json")

	hostname, err := os.Hostname()
	if err != nil {
		hostname = "stateful-app-0"
	}

	podName := getEnv("POD_NAME", hostname)
	pod := PodMetadata{
		PodName:      podName,
		PodNamespace: getEnv("POD_NAMESPACE", "statefulset-demo"),
		PodIP:        getEnv("POD_IP", "127.0.0.1"),
		NodeName:     getEnv("NODE_NAME", "kubernetes-node"),
		OrdinalIndex: extractOrdinal(podName),
	}

	store, err := newDataStore(storeFile)
	if err != nil {
		log.Fatalf("[FATAL] Failed to initialize datastore: %v", err)
	}

	startTime := time.Now()
	mux := http.NewServeMux()

	// GET / or /info
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" && r.URL.Path != "/info" {
			http.NotFound(w, r)
			return
		}

		total, free, used, pct := getDiskStats(dataDir)
		allRecords := store.getAll()

		var fileSize int64
		var modTime string
		if fi, err := os.Stat(storeFile); err == nil {
			fileSize = fi.Size()
			modTime = fi.ModTime().UTC().Format(time.RFC3339)
		}

		volStats := VolumeStats{
			MountPath:      dataDir,
			TotalBytes:     total,
			FreeBytes:      free,
			UsedBytes:      used,
			UsagePercent:   pct,
			RecordCount:    len(allRecords),
			FileSizeBytes:  fileSize,
			LastModifiedAt: modTime,
		}

		resp := map[string]interface{}{
			"service":        "stateful-app",
			"pod":            pod,
			"volume_stats":   volStats,
			"records_count":  len(allRecords),
			"uptime_seconds": time.Since(startTime).Seconds(),
			"timestamp":      time.Now().UTC(),
		}

		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Pod-Ordinal", fmt.Sprintf("%d", pod.OrdinalIndex))
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(resp)
	})

	// GET /data or POST /data
	mux.HandleFunc("/data", func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			key := r.URL.Query().Get("key")
			if key != "" {
				if item, found := store.get(key); found {
					w.Header().Set("Content-Type", "application/json")
					w.WriteHeader(http.StatusOK)
					_ = json.NewEncoder(w).Encode(item)
					return
				}
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusNotFound)
				_ = json.NewEncoder(w).Encode(map[string]string{"error": "key not found", "key": key})
				return
			}

			records := store.getAll()
			resp := map[string]interface{}{
				"pod_name":      pod.PodName,
				"ordinal_index": pod.OrdinalIndex,
				"total_records": len(records),
				"records":       records,
				"timestamp":     time.Now().UTC(),
			}

			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			_ = json.NewEncoder(w).Encode(resp)

		case http.MethodPost, http.MethodPut:
			body, err := io.ReadAll(io.LimitReader(r.Body, 1048576)) // 1MB limit
			if err != nil {
				http.Error(w, `{"error":"failed to read request body"}`, http.StatusBadRequest)
				return
			}
			defer r.Body.Close()

			var input struct {
				Key   string `json:"key"`
				Value string `json:"value"`
			}

			if err := json.Unmarshal(body, &input); err != nil || strings.TrimSpace(input.Key) == "" {
				http.Error(w, `{"error":"invalid payload; 'key' and 'value' required"}`, http.StatusBadRequest)
				return
			}

			item, err := store.set(input.Key, input.Value, pod.PodName)
			if err != nil {
				log.Printf("[ERROR] Write failed: %v", err)
				http.Error(w, fmt.Sprintf(`{"error":"failed to persist data: %v"}`, err), http.StatusInternalServerError)
				return
			}

			log.Printf("[INFO] Saved key=%s value=%s on %s", input.Key, input.Value, pod.PodName)
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusCreated)
			_ = json.NewEncoder(w).Encode(map[string]interface{}{
				"status":  "persisted",
				"record":  item,
				"pod":     pod.PodName,
				"ordinal": pod.OrdinalIndex,
			})

		default:
			w.WriteHeader(http.StatusMethodNotAllowed)
		}
	})

	// GET /peers (Resolves headless service DNS and queries sibling pods)
	mux.HandleFunc("/peers", func(w http.ResponseWriter, r *http.Request) {
		headlessService := getEnv("HEADLESS_SERVICE", "stateful-service")
		namespace := pod.PodNamespace
		domain := fmt.Sprintf("%s.%s.svc.cluster.local", headlessService, namespace)

		// Resolve headless domain IP list
		ips, err := net.LookupIP(domain)
		var resolvedIPs []string
		for _, ip := range ips {
			resolvedIPs = append(resolvedIPs, ip.String())
		}

		// Also check predictable peer hostnames: stateful-app-0, 1, 2
		peerStatuses := make(map[string]interface{})
		client := &http.Client{Timeout: 2 * time.Second}

		for i := 0; i < 3; i++ {
			peerHost := fmt.Sprintf("stateful-app-%d.%s.%s.svc.cluster.local", i, headlessService, namespace)
			peerURL := fmt.Sprintf("http://%s:%s/data", peerHost, port)

			resp, err := client.Get(peerURL)
			if err != nil {
				peerStatuses[fmt.Sprintf("stateful-app-%d", i)] = map[string]string{
					"status": "unreachable",
					"error":  err.Error(),
					"target": peerURL,
				}
				continue
			}

			body, _ := io.ReadAll(resp.Body)
			resp.Body.Close()

			var peerData map[string]interface{}
			if err := json.Unmarshal(body, &peerData); err == nil {
				peerStatuses[fmt.Sprintf("stateful-app-%d", i)] = map[string]interface{}{
					"status":  "healthy",
					"http_code": resp.StatusCode,
					"data":    peerData,
				}
			} else {
				peerStatuses[fmt.Sprintf("stateful-app-%d", i)] = map[string]interface{}{
					"status":    "connected",
					"http_code": resp.StatusCode,
					"raw":       string(body),
				}
			}
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"self_pod":        pod,
			"headless_domain": domain,
			"resolved_ips":    resolvedIPs,
			"lookup_error":    fmt.Sprintf("%v", err),
			"peers":           peerStatuses,
			"timestamp":       time.Now().UTC(),
		})
	})

	// Health Probes
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		// Verify data directory is writable
		testFile := filepath.Join(dataDir, ".health_probe")
		if err := os.WriteFile(testFile, []byte("ok"), 0644); err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusServiceUnavailable)
			_ = json.NewEncoder(w).Encode(map[string]string{"status": "unhealthy", "error": err.Error()})
			return
		}
		_ = os.Remove(testFile)

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "alive", "pod": pod.PodName, "ordinal": fmt.Sprintf("%d", pod.OrdinalIndex)})
	})

	mux.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "ready", "pod": pod.PodName, "ordinal": fmt.Sprintf("%d", pod.OrdinalIndex)})
	})

	server := &http.Server{
		Addr:         ":" + port,
		Handler:      mux,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  30 * time.Second,
	}

	go func() {
		log.Printf("[INFO] %s (Ordinal: %d) listening on :%s (DataDir: %s, StorageFile: %s)",
			pod.PodName, pod.OrdinalIndex, port, dataDir, storeFile)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("[FATAL] Server failure: %v", err)
		}
	}()

	shutdownChan := make(chan os.Signal, 1)
	signal.Notify(shutdownChan, os.Interrupt, syscall.SIGTERM, syscall.SIGINT)

	sig := <-shutdownChan
	log.Printf("[INFO] Received signal %v. Draining active connections...", sig)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		log.Printf("[ERROR] Server shutdown error: %v", err)
	} else {
		log.Printf("[INFO] Stateful server stopped cleanly.")
	}
}

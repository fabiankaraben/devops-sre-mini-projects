package portal

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"
)

// Server coordinates the HTTP routes and services.
type Server struct {
	store  *Store
	engine *Engine
	worker *Worker
	mux    *http.ServeMux
}

// NewServer initializes the HTTP API router and handlers.
func NewServer(store *Store, engine *Engine, worker *Worker) *Server {
	s := &Server{
		store:  store,
		engine: engine,
		worker: worker,
		mux:    http.NewServeMux(),
	}
	s.registerRoutes()
	return s
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Enable CORS & JSON headers
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")

	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusOK)
		return
	}

	s.mux.ServeHTTP(w, r)
}

func (s *Server) registerRoutes() {
	// Health & Metrics
	s.mux.HandleFunc("/healthz", s.handleHealthz)

	// REST API Routes (supporting both /api/v1/sandboxes and /sandboxes)
	s.mux.HandleFunc("/api/v1/sandboxes", s.handleSandboxes)
	s.mux.HandleFunc("/api/v1/sandboxes/", s.handleSandboxByID)
	s.mux.HandleFunc("/sandboxes", s.handleSandboxes)
	s.mux.HandleFunc("/sandboxes/", s.handleSandboxByID)
}

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	resp := HealthResponse{
		Status:          "healthy",
		Version:         "1.0.0",
		ActiveSandboxes: s.store.CountActive(),
		TotalSandboxes:  len(s.store.List()),
		Timestamp:       time.Now().UTC().Format(time.RFC3339),
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) handleSandboxes(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		sandboxes := s.store.List()
		activeCount := s.store.CountActive()
		resp := ListSandboxesResponse{
			Total:     len(sandboxes),
			Active:    activeCount,
			Sandboxes: sandboxes,
		}
		writeJSON(w, http.StatusOK, resp)

	case http.MethodPost:
		var req CreateSandboxRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, fmt.Sprintf("Invalid JSON body: %v", err), http.StatusBadRequest)
			return
		}

		if req.Name == "" {
			req.Name = "ephemeral-sandbox"
		}
		if req.DeveloperEmail == "" {
			req.DeveloperEmail = "developer@company.local"
		}
		if req.Template == "" {
			req.Template = "web-app"
		}
		if req.TTLSeconds <= 0 {
			req.TTLSeconds = 120 // Default: 2 minutes
		}

		// Generate random sandbox ID: sbx-xxxxxxxx
		randomBytes := make([]byte, 4)
		_, _ = rand.Read(randomBytes)
		sbxID := fmt.Sprintf("sbx-%s", hex.EncodeToString(randomBytes))

		now := time.Now().UTC()
		expiresAt := now.Add(time.Duration(req.TTLSeconds) * time.Second)

		sbx := &Sandbox{
			ID:                   sbxID,
			Name:                 req.Name,
			DeveloperEmail:       req.DeveloperEmail,
			Template:             req.Template,
			TTLSeconds:           req.TTLSeconds,
			Status:               StatusProvisioning,
			CreatedAt:            now,
			ExpiresAt:            expiresAt,
			TimeRemainingSeconds: req.TTLSeconds,
			Outputs:              make(map[string]interface{}),
		}

		if err := s.store.Save(sbx); err != nil {
			http.Error(w, fmt.Sprintf("Failed to record sandbox: %v", err), http.StatusInternalServerError)
			return
		}

		isAsync := r.URL.Query().Get("async") == "true"
		if isAsync {
			// Provision asynchronously in goroutine
			go func(target *Sandbox, params map[string]interface{}) {
				ctx, cancel := contextWithDefaultTimeout(10 * time.Minute)
				defer cancel()
				if err := s.engine.ProvisionSandbox(ctx, target, params); err != nil {
					target.Status = StatusFailed
					target.ErrorMessage = err.Error()
				} else {
					target.Status = StatusReady
				}
				_ = s.store.Save(target)
			}(sbx, req.Parameters)

			writeJSON(w, http.StatusAccepted, sbx)
			return
		}

		// Synchronous Provisioning
		log.Printf("[API] Provisioning sandbox %s (Template: %s, TTL: %ds)...", sbx.ID, sbx.Template, sbx.TTLSeconds)
		ctx, cancel := contextWithDefaultTimeout(10 * time.Minute)
		defer cancel()

		if err := s.engine.ProvisionSandbox(ctx, sbx, req.Parameters); err != nil {
			log.Printf("[API] ❌ Provisioning failed for %s: %v", sbx.ID, err)
			sbx.Status = StatusFailed
			sbx.ErrorMessage = err.Error()
			_ = s.store.Save(sbx)
			writeJSON(w, http.StatusInternalServerError, sbx)
			return
		}

		sbx.Status = StatusReady
		sbx.ComputeRemainingTime()
		_ = s.store.Save(sbx)
		log.Printf("[API] ✅ Sandbox %s is READY (Expires at %s)", sbx.ID, sbx.ExpiresAt.Format(time.RFC3339))
		writeJSON(w, http.StatusCreated, sbx)

	default:
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *Server) handleSandboxByID(w http.ResponseWriter, r *http.Request) {
	// Extract ID from path
	path := strings.TrimPrefix(r.URL.Path, "/api/v1/sandboxes/")
	path = strings.TrimPrefix(path, "/sandboxes/")
	id := strings.Split(path, "/")[0]

	if id == "" {
		http.Error(w, "Sandbox ID is required", http.StatusBadRequest)
		return
	}

	sbx, found := s.store.Get(id)
	if !found {
		http.Error(w, fmt.Sprintf("Sandbox '%s' not found", id), http.StatusNotFound)
		return
	}

	switch r.Method {
	case http.MethodGet:
		sbx.ComputeRemainingTime()
		writeJSON(w, http.StatusOK, sbx)

	case http.MethodDelete:
		if sbx.Status == StatusDestroyed {
			writeJSON(w, http.StatusOK, map[string]string{
				"message": fmt.Sprintf("Sandbox %s is already destroyed", id),
				"status":  string(StatusDestroyed),
			})
			return
		}

		log.Printf("[API] 🗑️ Manual destruction requested for sandbox %s...", id)
		sbx.Status = StatusDestroying
		_ = s.store.Save(sbx)

		ctx, cancel := contextWithDefaultTimeout(5 * time.Minute)
		defer cancel()

		if err := s.engine.DestroySandbox(ctx, sbx); err != nil {
			log.Printf("[API] ❌ Error destroying sandbox %s: %v", id, err)
			sbx.Status = StatusFailed
			sbx.ErrorMessage = err.Error()
			_ = s.store.Save(sbx)
			writeJSON(w, http.StatusInternalServerError, sbx)
			return
		}

		sbx.Status = StatusDestroyed
		sbx.ComputeRemainingTime()
		_ = s.store.Save(sbx)
		log.Printf("[API] ✅ Sandbox %s successfully deleted.", id)
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"message": fmt.Sprintf("Sandbox %s successfully destroyed", id),
			"sandbox": sbx,
		})

	default:
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
	}
}

func contextWithDefaultTimeout(d time.Duration) (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), d)
}

func writeJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(data)
}

package portal

import (
	"time"
)

// SandboxStatus represents the lifecycle state of an ephemeral cloud sandbox.
type SandboxStatus string

const (
	StatusProvisioning SandboxStatus = "PROVISIONING"
	StatusReady        SandboxStatus = "READY"
	StatusFailed       SandboxStatus = "FAILED"
	StatusDestroying   SandboxStatus = "DESTROYING"
	StatusDestroyed    SandboxStatus = "DESTROYED"
)

// CreateSandboxRequest represents the payload developers send to request a sandbox.
type CreateSandboxRequest struct {
	Name           string                 `json:"name"`
	DeveloperEmail string                 `json:"developer_email"`
	Template       string                 `json:"template"` // e.g. "web-app" or "microservice"
	TTLSeconds     int                    `json:"ttl_seconds"`
	Parameters     map[string]interface{} `json:"parameters,omitempty"`
}

// Sandbox represents a managed ephemeral cloud environment.
type Sandbox struct {
	ID                   string                 `json:"id"`
	Name                 string                 `json:"name"`
	DeveloperEmail       string                 `json:"developer_email"`
	Template             string                 `json:"template"`
	TTLSeconds           int                    `json:"ttl_seconds"`
	Status               SandboxStatus          `json:"status"`
	CreatedAt            time.Time              `json:"created_at"`
	ExpiresAt            time.Time              `json:"expires_at"`
	TimeRemainingSeconds int                    `json:"time_remaining_seconds"`
	Outputs              map[string]interface{} `json:"outputs,omitempty"`
	ErrorMessage         string                 `json:"error_message,omitempty"`
	WorkspaceDir         string                 `json:"workspace_dir"`
	LogFile              string                 `json:"log_file"`
}

// ComputeRemainingTime updates the dynamic remaining TTL in seconds.
func (s *Sandbox) ComputeRemainingTime() {
	if s.Status == StatusDestroyed || s.Status == StatusFailed {
		s.TimeRemainingSeconds = 0
		return
	}
	rem := int(time.Until(s.ExpiresAt).Seconds())
	if rem < 0 {
		rem = 0
	}
	s.TimeRemainingSeconds = rem
}

// ListSandboxesResponse represents the response format for GET /api/v1/sandboxes.
type ListSandboxesResponse struct {
	Total     int        `json:"total"`
	Active    int        `json:"active"`
	Sandboxes []*Sandbox `json:"sandboxes"`
}

// HealthResponse represents the health check status.
type HealthResponse struct {
	Status          string `json:"status"`
	Version         string `json:"version"`
	ActiveSandboxes int    `json:"active_sandboxes"`
	TotalSandboxes  int    `json:"total_sandboxes"`
	Timestamp       string `json:"timestamp"`
}

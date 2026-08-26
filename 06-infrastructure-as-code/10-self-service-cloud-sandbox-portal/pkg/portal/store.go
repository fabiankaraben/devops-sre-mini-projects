package portal

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

// Store manages in-memory and persistent storage for sandboxes.
type Store struct {
	mu        sync.RWMutex
	sandboxes map[string]*Sandbox
	filePath  string
}

// NewStore creates a new thread-safe sandbox repository.
func NewStore(dataFile string) (*Store, error) {
	s := &Store{
		sandboxes: make(map[string]*Sandbox),
		filePath:  dataFile,
	}

	if dataFile != "" {
		if err := os.MkdirAll(filepath.Dir(dataFile), 0755); err != nil {
			return nil, fmt.Errorf("failed to create data dir: %w", err)
		}
		_ = s.load()
	}

	return s, nil
}

// Save stores or updates a sandbox.
func (s *Store) Save(sbx *Sandbox) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.sandboxes[sbx.ID] = sbx
	return s.persist()
}

// Get retrieves a sandbox by its unique ID.
func (s *Store) Get(id string) (*Sandbox, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	sbx, found := s.sandboxes[id]
	if !found {
		return nil, false
	}
	sbx.ComputeRemainingTime()
	return sbx, true
}

// List returns a slice of all stored sandboxes.
func (s *Store) List() []*Sandbox {
	s.mu.RLock()
	defer s.mu.RUnlock()

	list := make([]*Sandbox, 0, len(s.sandboxes))
	for _, sbx := range s.sandboxes {
		sbx.ComputeRemainingTime()
		list = append(list, sbx)
	}
	return list
}

// CountActive returns the number of non-destroyed/non-failed sandboxes.
func (s *Store) CountActive() int {
	s.mu.RLock()
	defer s.mu.RUnlock()

	count := 0
	for _, sbx := range s.sandboxes {
		if sbx.Status == StatusReady || sbx.Status == StatusProvisioning {
			count++
		}
	}
	return count
}

func (s *Store) persist() error {
	if s.filePath == "" {
		return nil
	}
	data, err := json.MarshalIndent(s.sandboxes, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(s.filePath, data, 0644)
}

func (s *Store) load() error {
	if _, err := os.Stat(s.filePath); os.IsNotExist(err) {
		return nil
	}
	data, err := os.ReadFile(s.filePath)
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return json.Unmarshal(data, &s.sandboxes)
}

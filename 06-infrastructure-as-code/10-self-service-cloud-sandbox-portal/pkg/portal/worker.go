package portal

import (
	"context"
	"log"
	"time"
)

// Worker monitors sandbox TTLs and automatically triggers teardown when expired.
type Worker struct {
	store    *Store
	engine   *Engine
	interval time.Duration
	stopCh   chan struct{}
}

// NewWorker creates a new background TTL expiration monitor.
func NewWorker(store *Store, engine *Engine, interval time.Duration) *Worker {
	if interval <= 0 {
		interval = 1 * time.Second
	}
	return &Worker{
		store:    store,
		engine:   engine,
		interval: interval,
		stopCh:   make(chan struct{}),
	}
}

// Start begins the background monitoring loop in a goroutine.
func (w *Worker) Start(ctx context.Context) {
	go func() {
		ticker := time.NewTicker(w.interval)
		defer ticker.Stop()

		log.Printf("[Worker] TTL Expiration Worker started (interval: %v)", w.interval)

		for {
			select {
			case <-ctx.Done():
				log.Println("[Worker] Context cancelled, shutting down TTL worker.")
				return
			case <-w.stopCh:
				log.Println("[Worker] Stop signal received, shutting down TTL worker.")
				return
			case <-ticker.C:
				w.checkExpirations(ctx)
			}
		}
	}()
}

// Stop terminates the worker.
func (w *Worker) Stop() {
	close(w.stopCh)
}

func (w *Worker) checkExpirations(ctx context.Context) {
	sandboxes := w.store.List()
	now := time.Now()

	for _, sbx := range sandboxes {
		if sbx.Status == StatusReady && now.After(sbx.ExpiresAt) {
			log.Printf("[Worker] ⏰ Sandbox %s (owner: %s) has EXPIRED (TTL was %ds). Triggering automated teardown...",
				sbx.ID, sbx.DeveloperEmail, sbx.TTLSeconds)

			// Mark as destroying
			sbx.Status = StatusDestroying
			_ = w.store.Save(sbx)

			// Run destruction in background or inline
			go func(target *Sandbox) {
				destroyCtx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
				defer cancel()

				if err := w.engine.DestroySandbox(destroyCtx, target); err != nil {
					log.Printf("[Worker] ❌ Failed to destroy expired sandbox %s: %v", target.ID, err)
					target.Status = StatusFailed
					target.ErrorMessage = err.Error()
				} else {
					log.Printf("[Worker] ✅ Sandbox %s successfully destroyed and cloud resources cleaned up.", target.ID)
					target.Status = StatusDestroyed
				}
				_ = w.store.Save(target)
			}(sbx)
		}
	}
}

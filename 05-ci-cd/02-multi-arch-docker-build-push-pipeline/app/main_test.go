package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"runtime"
	"strings"
	"testing"
)

func TestRootHandler(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rr := httptest.NewRecorder()

	rootHandler(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rr.Code)
	}

	var body map[string]interface{}
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatalf("failed to decode JSON response: %v", err)
	}

	if body["architecture"] != runtime.GOARCH {
		t.Errorf("expected architecture %s, got %v", runtime.GOARCH, body["architecture"])
	}
	if body["os"] != runtime.GOOS {
		t.Errorf("expected os %s, got %v", runtime.GOOS, body["os"])
	}

	// Test 404 on unmapped subpath
	req404 := httptest.NewRequest(http.MethodGet, "/nonexistent", nil)
	rr404 := httptest.NewRecorder()
	rootHandler(rr404, req404)
	if rr404.Code != http.StatusNotFound {
		t.Errorf("expected status 404 for subpath, got %d", rr404.Code)
	}
}

func TestHealthzHandler(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rr := httptest.NewRecorder()

	healthzHandler(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rr.Code)
	}

	var resp HealthResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("failed to parse health response: %v", err)
	}

	if resp.Status != "healthy" {
		t.Errorf("expected status 'healthy', got %s", resp.Status)
	}
}

func TestInfoHandler(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/info", nil)
	rr := httptest.NewRecorder()

	infoHandler(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rr.Code)
	}

	var resp InfoResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("failed to parse info response: %v", err)
	}

	if resp.Architecture != runtime.GOARCH {
		t.Errorf("expected architecture %s, got %s", runtime.GOARCH, resp.Architecture)
	}
	if resp.OS != runtime.GOOS {
		t.Errorf("expected OS %s, got %s", runtime.GOOS, resp.OS)
	}
	if resp.Service != "multiarch-demo-service" {
		t.Errorf("expected service name 'multiarch-demo-service', got %s", resp.Service)
	}
	if resp.NumCPU <= 0 {
		t.Errorf("expected positive CPU count, got %d", resp.NumCPU)
	}
}

func TestMetricsHandler(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	rr := httptest.NewRecorder()

	metricsHandler(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rr.Code)
	}

	body := rr.Body.String()
	if !strings.Contains(body, "service_uptime_seconds") {
		t.Errorf("expected metrics to include 'service_uptime_seconds'")
	}
	if !strings.Contains(body, "service_requests_total") {
		t.Errorf("expected metrics to include 'service_requests_total'")
	}
	if !strings.Contains(body, "service_go_info") {
		t.Errorf("expected metrics to include 'service_go_info'")
	}
}

// =============================================================================
// smoke_test.js - Grafana k6 Sanity & Baseline Smoke Test
// =============================================================================
// Minimal load test verifying API availability, endpoint correctness, and basic
// response schemas before launching intensive stress tests.
// =============================================================================

import http from 'k6/http';
import { check, group, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// Custom Metrics
const orderTrend = new Trend('order_placement_duration', true);
const errorRate = new Rate('custom_error_rate');

export const options = {
  vus: 1,
  duration: '5s',
  thresholds: {
    http_req_duration: ['p(95)<150', 'p(99)<250'], // 95% of requests must complete under 150ms
    http_req_failed: ['rate<0.01'],                 // Error rate must be less than 1%
    checks: ['rate>0.99'],                          // 99%+ of checks must pass
  },
};

const BASE_URL = __ENV.TARGET_URL || 'http://localhost:8080';

export default function () {
  const headers = { 'Content-Type': 'application/json' };

  // 1. Healthcheck Probe
  group('01_Healthcheck', function () {
    const res = http.get(`${BASE_URL}/health`);
    const passed = check(res, {
      'health status is 200': (r) => r.status === 200,
      'service is healthy': (r) => JSON.parse(r.body).status === 'healthy',
    });
    errorRate.add(!passed);
  });

  // 2. Catalog Browsing
  group('02_BrowseCatalog', function () {
    const res = http.get(`${BASE_URL}/api/v1/products?limit=5`);
    const passed = check(res, {
      'catalog status is 200': (r) => r.status === 200,
      'has product items': (r) => JSON.parse(r.body).items.length > 0,
    });
    errorRate.add(!passed);
  });

  // 3. Product Detail View
  group('03_ProductDetail', function () {
    const res = http.get(`${BASE_URL}/api/v1/products/1`);
    const passed = check(res, {
      'product detail status is 200': (r) => r.status === 200,
      'product ID matches': (r) => JSON.parse(r.body).id === 1,
    });
    errorRate.add(!passed);
  });

  // 4. Order Checkout
  group('04_OrderCheckout', function () {
    const orderPayload = JSON.stringify({
      user_id: 'usr_smoke_001',
      items: [
        { product_id: 1, quantity: 2 },
        { product_id: 3, quantity: 1 },
      ],
    });

    const res = http.post(`${BASE_URL}/api/v1/orders`, orderPayload, { headers });
    orderTrend.add(res.timings.duration);

    const passed = check(res, {
      'order creation status is 201': (r) => r.status === 201,
      'order is confirmed': (r) => JSON.parse(r.body).status === 'CONFIRMED',
    });
    errorRate.add(!passed);
  });

  sleep(0.5);
}

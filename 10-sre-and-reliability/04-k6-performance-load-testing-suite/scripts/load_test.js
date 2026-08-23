// =============================================================================
// load_test.js - Grafana k6 Ramping Load Test & SRE SLO Validation
// =============================================================================
// Simulates realistic multi-stage user journeys with strict percentile latency
// SLO thresholds (p95 < 200ms, error rate < 1%).
// =============================================================================

import http from 'k6/http';
import { check, group, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

// Custom SRE Metrics
const orderTrend = new Trend('order_duration', true);
const catalogTrend = new Trend('catalog_browse_duration', true);
const successfulOrders = new Counter('orders_placed_total');
const errorRate = new Rate('business_error_rate');

export const options = {
  stages: [
    { duration: '5s', target: 10 },  // Stage 1: Warmup to 10 VUs
    { duration: '15s', target: 25 }, // Stage 2: Peak sustained load at 25 VUs
    { duration: '5s', target: 0 },   // Stage 3: Graceful cooldown
  ],
  thresholds: {
    // SRE Service Level Objectives (SLOs)
    'http_req_duration': ['p(90)<120', 'p(95)<200', 'p(99)<350'],
    'http_req_failed': ['rate<0.01'], // Global HTTP failure rate < 1%
    'checks': ['rate>0.99'],          // 99%+ of all functional assertions must pass
    'order_duration': ['p(95)<250'],  // Orders write latency p95 < 250ms
    'business_error_rate': ['rate<0.01'],
  },
};

const BASE_URL = __ENV.TARGET_URL || 'http://localhost:8080';

export default function () {
  const headers = { 'Content-Type': 'application/json' };
  const randomUserId = `usr_${__VU}_${__ITER}`;
  const randomProductId = Math.floor(Math.random() * 20) + 1;

  // Step 1: Healthcheck Probe
  const healthRes = http.get(`${BASE_URL}/health`, { tags: { name: 'Healthcheck' } });
  check(healthRes, {
    'health 200 OK': (r) => r.status === 200,
  });

  // Step 2: Browse Product Catalog
  group('Catalog_Browse', function () {
    const page = Math.floor(Math.random() * 2) + 1;
    const catRes = http.get(`${BASE_URL}/api/v1/products?page=${page}&limit=8`, {
      tags: { name: 'GetCatalog' },
    });
    catalogTrend.add(catRes.timings.duration);

    const passed = check(catRes, {
      'catalog response is 200': (r) => r.status === 200,
      'catalog items exist': (r) => JSON.parse(r.body).items && JSON.parse(r.body).items.length > 0,
    });
    errorRate.add(!passed);
  });

  // Simulated user think time
  sleep(Math.random() * 0.2 + 0.1);

  // Step 3: Product Detail View
  group('Product_Detail', function () {
    const prodRes = http.get(`${BASE_URL}/api/v1/products/${randomProductId}`, {
      tags: { name: 'GetProductDetail' },
    });

    const passed = check(prodRes, {
      'product detail is 200': (r) => r.status === 200,
      'product ID is correct': (r) => JSON.parse(r.body).id === randomProductId,
    });
    errorRate.add(!passed);
  });

  // Simulated user checkout deliberation
  sleep(Math.random() * 0.2 + 0.1);

  // Step 4: Order Placement (Conversion Journey ~50% of traffic)
  if (Math.random() < 0.5) {
    group('Order_Checkout', function () {
      const payload = JSON.stringify({
        user_id: randomUserId,
        items: [
          { product_id: randomProductId, quantity: Math.floor(Math.random() * 3) + 1 },
        ],
      });

      const orderRes = http.post(`${BASE_URL}/api/v1/orders`, payload, {
        headers,
        tags: { name: 'CreateOrder' },
      });
      orderTrend.add(orderRes.timings.duration);

      const passed = check(orderRes, {
        'order status is 201': (r) => r.status === 201,
        'order is confirmed': (r) => JSON.parse(r.body).status === 'CONFIRMED',
        'has valid order_id': (r) => JSON.parse(r.body).order_id !== undefined,
      });

      if (passed) {
        successfulOrders.add(1);
      }
      errorRate.add(!passed);
    });
  }

  // Inter-iteration delay
  sleep(0.2);
}

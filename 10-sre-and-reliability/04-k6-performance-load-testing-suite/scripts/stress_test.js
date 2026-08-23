// =============================================================================
// stress_test.js - Grafana k6 System Capacity & Breaking Point Stress Test
// =============================================================================
// Ramps traffic beyond standard peak capacity to observe degradation behavior,
// saturation points, and error rates under heavy concurrency.
// =============================================================================

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const stressDuration = new Trend('stress_req_duration', true);
const errorRate = new Rate('stress_error_rate');

export const options = {
  stages: [
    { duration: '5s', target: 20 },  // Ramp to 20 VUs
    { duration: '10s', target: 50 }, // Ramp to 50 VUs (Stress load)
    { duration: '5s', target: 0 },   // Ramp down
  ],
  thresholds: {
    'http_req_duration': ['p(95)<250'],
    'http_req_failed': ['rate<0.02'], // Error rate under stress must remain < 2%
    'checks': ['rate>0.98'],
  },
};

const BASE_URL = __ENV.TARGET_URL || 'http://localhost:8080';

export default function () {
  const headers = { 'Content-Type': 'application/json' };
  const prodId = Math.floor(Math.random() * 25) + 1;

  // Mix of reads and writes under stress
  if (Math.random() < 0.7) {
    const res = http.get(`${BASE_URL}/api/v1/products/${prodId}`);
    stressDuration.add(res.timings.duration);
    const passed = check(res, { 'status is 200': (r) => r.status === 200 });
    errorRate.add(!passed);
  } else {
    const payload = JSON.stringify({
      user_id: `usr_stress_${__VU}`,
      items: [{ product_id: prodId, quantity: 1 }],
    });
    const res = http.post(`${BASE_URL}/api/v1/orders`, payload, { headers });
    stressDuration.add(res.timings.duration);
    const passed = check(res, { 'order is 201': (r) => r.status === 201 });
    errorRate.add(!passed);
  }

  sleep(0.05);
}

// =============================================================================
// spike_test.js - Grafana k6 Traffic Spike & Recovery Performance Test
// =============================================================================
// Simulates an instantaneous surge in traffic from 0 to 40 VUs within 3 seconds,
// evaluating autoscaling capability and recovery without prolonged error tails.
// =============================================================================

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const spikeTrend = new Trend('spike_duration', true);
const errorRate = new Rate('spike_error_rate');

export const options = {
  stages: [
    { duration: '3s', target: 5 },   // Low baseline
    { duration: '3s', target: 40 },  // Instantaneous explosive traffic spike!
    { duration: '8s', target: 40 },  // Peak plateau
    { duration: '3s', target: 5 },   // Rapid recovery
    { duration: '3s', target: 0 },   // Cooldown
  ],
  thresholds: {
    'http_req_duration': ['p(95)<300'],
    'http_req_failed': ['rate<0.05'], // Spike error tolerance < 5%
    'checks': ['rate>0.95'],
  },
};

const BASE_URL = __ENV.TARGET_URL || 'http://localhost:8080';

export default function () {
  const res = http.get(`${BASE_URL}/api/v1/products?limit=10`);
  spikeTrend.add(res.timings.duration);

  const passed = check(res, {
    'status is 200': (r) => r.status === 200,
  });
  errorRate.add(!passed);

  sleep(0.05);
}

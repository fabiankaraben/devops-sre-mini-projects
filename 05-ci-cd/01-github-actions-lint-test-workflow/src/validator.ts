/**
 * SRE and SLO Input Validation Utilities
 */

export interface TimeWindowConfig {
  days: number;
  totalSeconds: number;
}

export interface MetricInput {
  targetAvailabilityPercent: number;
  totalRequests: number;
  failedRequests: number;
  windowDays?: number;
}

/**
 * Validates that an availability target percentage is strictly between 0 and 100 (exclusive).
 * e.g., 99.9, 99.99, etc.
 */
export function validateAvailabilityTarget(target: number): void {
  if (typeof target !== 'number' || Number.isNaN(target)) {
    throw new TypeError('Availability target must be a valid number');
  }
  if (target <= 0 || target >= 100) {
    throw new RangeError(`Availability target must be strictly between 0 and 100 (received: ${target})`);
  }
}

/**
 * Validates request counts ensuring non-negative numbers and failed <= total.
 */
export function validateRequestCounts(totalRequests: number, failedRequests: number): void {
  if (!Number.isInteger(totalRequests) || totalRequests < 0) {
    throw new TypeError(`Total requests must be a non-negative integer (received: ${totalRequests})`);
  }
  if (!Number.isInteger(failedRequests) || failedRequests < 0) {
    throw new TypeError(`Failed requests must be a non-negative integer (received: ${failedRequests})`);
  }
  if (failedRequests > totalRequests) {
    throw new RangeError(
      `Failed requests (${failedRequests}) cannot exceed total requests (${totalRequests})`
    );
  }
}

/**
 * Validates incident durations array ensuring non-empty and non-negative values.
 */
export function validateIncidentDurations(durationsMinutes: number[]): void {
  if (!Array.isArray(durationsMinutes) || durationsMinutes.length === 0) {
    throw new TypeError('Incident durations must be a non-empty array of numbers');
  }
  for (const duration of durationsMinutes) {
    if (typeof duration !== 'number' || Number.isNaN(duration) || duration < 0) {
      throw new RangeError(`Incident duration must be a non-negative number (received: ${duration})`);
    }
  }
}

/**
 * Validates time window in days ensuring it is a positive integer.
 */
export function validateWindowDays(windowDays: number): TimeWindowConfig {
  if (!Number.isInteger(windowDays) || windowDays <= 0) {
    throw new RangeError(`Window days must be a positive integer (received: ${windowDays})`);
  }
  const SECONDS_PER_DAY = 86400;
  return {
    days: windowDays,
    totalSeconds: windowDays * SECONDS_PER_DAY,
  };
}

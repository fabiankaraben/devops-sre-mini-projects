/**
 * SRE & SLO Availability, Error Budget, MTTR, and Burn Rate Calculations
 */

import {
  validateAvailabilityTarget,
  validateRequestCounts,
  validateIncidentDurations,
  validateWindowDays,
} from './validator.js';

export interface DowntimeBudget {
  targetAvailabilityPercent: number;
  allowedDowntimeSeconds: number;
  allowedDowntimeMinutes: number;
  allowedDowntimeHours: number;
  windowDays: number;
}

export interface ErrorBudgetStatus {
  targetAvailabilityPercent: number;
  totalRequests: number;
  failedRequests: number;
  successfulRequests: number;
  actualAvailabilityPercent: number;
  totalAllowedErrors: number;
  remainingAllowedErrors: number;
  consumedBudgetPercent: number;
  isBudgetExhausted: boolean;
}

export interface BurnRateResult {
  burnRate: number;
  consumedBudgetPercent: number;
  windowDays: number;
  hoursUntilExhaustion: number | null;
  severity: 'HEALTHY' | 'WARNING' | 'CRITICAL';
}

/**
 * Calculates allowable downtime budget for a given availability target and time window.
 * Formula: Allowed Downtime = Total Time * (1 - Availability Target)
 */
export function calculateAllowedDowntime(
  targetAvailabilityPercent: number,
  windowDays = 30
): DowntimeBudget {
  validateAvailabilityTarget(targetAvailabilityPercent);
  const timeWindow = validateWindowDays(windowDays);

  const unavailabilityRatio = (100 - targetAvailabilityPercent) / 100;
  const allowedDowntimeSeconds = Number((timeWindow.totalSeconds * unavailabilityRatio).toFixed(4));
  const allowedDowntimeMinutes = allowedDowntimeSeconds / 60;
  const allowedDowntimeHours = allowedDowntimeMinutes / 60;

  return {
    targetAvailabilityPercent,
    allowedDowntimeSeconds: Number(allowedDowntimeSeconds.toFixed(2)),
    allowedDowntimeMinutes: Number(allowedDowntimeMinutes.toFixed(2)),
    allowedDowntimeHours: Number(allowedDowntimeHours.toFixed(4)),
    windowDays: timeWindow.days,
  };
}

/**
 * Calculates Error Budget consumption and current availability from request telemetry.
 */
export function calculateErrorBudget(
  targetAvailabilityPercent: number,
  totalRequests: number,
  failedRequests: number
): ErrorBudgetStatus {
  validateAvailabilityTarget(targetAvailabilityPercent);
  validateRequestCounts(totalRequests, failedRequests);

  if (totalRequests === 0) {
    return {
      targetAvailabilityPercent,
      totalRequests: 0,
      failedRequests: 0,
      successfulRequests: 0,
      actualAvailabilityPercent: 100,
      totalAllowedErrors: 0,
      remainingAllowedErrors: 0,
      consumedBudgetPercent: 0,
      isBudgetExhausted: false,
    };
  }

  const successfulRequests = totalRequests - failedRequests;
  const actualAvailabilityPercent = (successfulRequests / totalRequests) * 100;

  // Protect against IEEE-754 floating point subtraction inaccuracies (e.g. 100 - 99.9 = 0.09999999999999432)
  const allowedErrorRate = Number(((100 - targetAvailabilityPercent) / 100).toFixed(6));
  const totalAllowedErrors = Math.floor(Number((totalRequests * allowedErrorRate).toFixed(4)));
  const remainingAllowedErrors = totalAllowedErrors - failedRequests;

  let consumedBudgetPercent = 0;
  if (totalAllowedErrors > 0) {
    consumedBudgetPercent = (failedRequests / totalAllowedErrors) * 100;
  } else if (failedRequests > 0) {
    consumedBudgetPercent = 100;
  }

  const isBudgetExhausted = remainingAllowedErrors < 0 || (totalAllowedErrors === 0 && failedRequests > 0);

  return {
    targetAvailabilityPercent,
    totalRequests,
    failedRequests,
    successfulRequests,
    actualAvailabilityPercent: Number(actualAvailabilityPercent.toFixed(4)),
    totalAllowedErrors,
    remainingAllowedErrors,
    consumedBudgetPercent: Number(consumedBudgetPercent.toFixed(2)),
    isBudgetExhausted,
  };
}

/**
 * Calculates Mean Time to Recovery (MTTR) from an array of incident durations in minutes.
 */
export function calculateMTTR(durationsMinutes: number[]): number {
  validateIncidentDurations(durationsMinutes);
  const totalDuration = durationsMinutes.reduce((acc, curr) => acc + curr, 0);
  const mttr = totalDuration / durationsMinutes.length;
  return Number(mttr.toFixed(2));
}

/**
 * Calculates Error Budget Burn Rate over a given observation window.
 * Burn Rate 1.0 = Consumes 100% of error budget over the full window (e.g. 30 days).
 * Burn Rate > 1.0 = Burning budget faster than the target SLO allows.
 */
export function calculateBurnRate(
  consumedBudgetPercent: number,
  observedHours: number,
  totalWindowDays = 30
): BurnRateResult {
  if (typeof consumedBudgetPercent !== 'number' || consumedBudgetPercent < 0) {
    throw new RangeError('Consumed budget percent must be a non-negative number');
  }
  if (typeof observedHours !== 'number' || observedHours <= 0) {
    throw new RangeError('Observed hours must be a positive number');
  }
  const timeWindow = validateWindowDays(totalWindowDays);
  const totalWindowHours = timeWindow.days * 24;

  const expectedConsumptionPercent = (observedHours / totalWindowHours) * 100;
  const burnRate = Number((consumedBudgetPercent / expectedConsumptionPercent).toFixed(2));

  let hoursUntilExhaustion: number | null = null;
  if (consumedBudgetPercent < 100 && burnRate > 0) {
    const remainingPercent = 100 - consumedBudgetPercent;
    const consumptionPerHour = consumedBudgetPercent / observedHours;
    hoursUntilExhaustion = Number((remainingPercent / consumptionPerHour).toFixed(2));
  } else if (consumedBudgetPercent >= 100) {
    hoursUntilExhaustion = 0;
  }

  let severity: 'HEALTHY' | 'WARNING' | 'CRITICAL' = 'HEALTHY';
  if (burnRate >= 14.4 || consumedBudgetPercent >= 100) {
    // 14.4x burn rate exhausts 100% budget in 2 days (Google SRE Alerting standard)
    severity = 'CRITICAL';
  } else if (burnRate >= 2.0) {
    severity = 'WARNING';
  }

  return {
    burnRate,
    consumedBudgetPercent,
    windowDays: timeWindow.days,
    hoursUntilExhaustion,
    severity,
  };
}

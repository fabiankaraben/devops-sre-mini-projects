import { describe, it, expect } from 'vitest';
import {
  calculateAllowedDowntime,
  calculateErrorBudget,
  calculateMTTR,
  calculateBurnRate,
} from '../src/calculator.js';

describe('SRE Calculator Utilities', () => {
  describe('calculateAllowedDowntime', () => {
    it('should accurately calculate allowed downtime for 99.9% (Three Nines) over 30 days', () => {
      // 30 days = 2,592,000 seconds. 0.1% = 2,592 seconds = 43.2 minutes
      const result = calculateAllowedDowntime(99.9, 30);
      expect(result.targetAvailabilityPercent).toBe(99.9);
      expect(result.allowedDowntimeSeconds).toBe(2592);
      expect(result.allowedDowntimeMinutes).toBe(43.2);
      expect(result.allowedDowntimeHours).toBe(0.72);
      expect(result.windowDays).toBe(30);
    });

    it('should accurately calculate allowed downtime for 99.99% (Four Nines) over 30 days', () => {
      // 30 days * 0.01% = 259.2 seconds = 4.32 minutes
      const result = calculateAllowedDowntime(99.99, 30);
      expect(result.allowedDowntimeMinutes).toBe(4.32);
    });
  });

  describe('calculateErrorBudget', () => {
    it('should handle zero total requests gracefully', () => {
      const result = calculateErrorBudget(99.9, 0, 0);
      expect(result.totalRequests).toBe(0);
      expect(result.actualAvailabilityPercent).toBe(100);
      expect(result.consumedBudgetPercent).toBe(0);
      expect(result.isBudgetExhausted).toBe(false);
    });

    it('should compute remaining budget accurately when within SLO', () => {
      // 1,000,000 requests with 99.9% target => 1,000 allowed errors
      // 250 failed => 25% consumed, 750 remaining
      const result = calculateErrorBudget(99.9, 1000000, 250);
      expect(result.totalAllowedErrors).toBe(1000);
      expect(result.remainingAllowedErrors).toBe(750);
      expect(result.consumedBudgetPercent).toBe(25);
      expect(result.actualAvailabilityPercent).toBe(99.975);
      expect(result.isBudgetExhausted).toBe(false);
    });

    it('should identify exhausted budget when failures exceed allowed budget', () => {
      // 1,000,000 requests, 1,200 failures with 1,000 allowed => 120% consumed
      const result = calculateErrorBudget(99.9, 1000000, 1200);
      expect(result.totalAllowedErrors).toBe(1000);
      expect(result.remainingAllowedErrors).toBe(-200);
      expect(result.consumedBudgetPercent).toBe(120);
      expect(result.isBudgetExhausted).toBe(true);
    });

    it('should handle tight SLO where allowed error count rounds to zero', () => {
      // 100 requests with 99.99% target => floor(0.01) = 0 allowed errors
      const result = calculateErrorBudget(99.99, 100, 1);
      expect(result.totalAllowedErrors).toBe(0);
      expect(result.isBudgetExhausted).toBe(true);
      expect(result.consumedBudgetPercent).toBe(100);
    });
  });

  describe('calculateMTTR', () => {
    it('should calculate mean recovery time across multiple incident durations', () => {
      const incidents = [10, 20, 30, 40]; // Total: 100 / 4 = 25.0
      expect(calculateMTTR(incidents)).toBe(25.0);
    });

    it('should handle single incident duration correctly', () => {
      expect(calculateMTTR([15.75])).toBe(15.75);
    });
  });

  describe('calculateBurnRate', () => {
    it('should calculate 1.0x standard burn rate correctly', () => {
      // Over 24 hours (1 day out of 30), expected consumption is 1/30 = 3.333%
      // If 3.33% consumed, burn rate is ~1.0
      const result = calculateBurnRate(3.333, 24, 30);
      expect(result.burnRate).toBe(1.0);
      expect(result.severity).toBe('HEALTHY');
      expect(result.hoursUntilExhaustion).toBeGreaterThan(0);
    });

    it('should mark critical severity when burn rate exceeds 14.4x', () => {
      // Consumed 50% of budget in 24 hours of a 30-day window
      // Expected: 3.333%. Burn rate = 50 / 3.333 = 15.0x
      const result = calculateBurnRate(50, 24, 30);
      expect(result.burnRate).toBe(15.0);
      expect(result.severity).toBe('CRITICAL');
      expect(result.hoursUntilExhaustion).toBe(24);
    });

    it('should return 0 hours until exhaustion if budget is already 100% consumed', () => {
      const result = calculateBurnRate(100, 10, 30);
      expect(result.hoursUntilExhaustion).toBe(0);
      expect(result.severity).toBe('CRITICAL');
    });

    it('should reject invalid input parameters', () => {
      expect(() => calculateBurnRate(-1, 24, 30)).toThrow(RangeError);
      expect(() => calculateBurnRate(50, 0, 30)).toThrow(RangeError);
    });
  });
});

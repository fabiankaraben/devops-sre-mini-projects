import { describe, it, expect } from 'vitest';
import {
  validateAvailabilityTarget,
  validateRequestCounts,
  validateIncidentDurations,
  validateWindowDays,
} from '../src/validator.js';

describe('SRE Validator Utilities', () => {
  describe('validateAvailabilityTarget', () => {
    it('should accept valid percentage targets', () => {
      expect(() => validateAvailabilityTarget(99.9)).not.toThrow();
      expect(() => validateAvailabilityTarget(99.99)).not.toThrow();
      expect(() => validateAvailabilityTarget(50.0)).not.toThrow();
    });

    it('should reject non-number types and NaN', () => {
      // @ts-expect-error Testing invalid type input
      expect(() => validateAvailabilityTarget('99.9')).toThrow(TypeError);
      expect(() => validateAvailabilityTarget(Number.NaN)).toThrow(TypeError);
    });

    it('should reject out-of-bounds percentages (<= 0 or >= 100)', () => {
      expect(() => validateAvailabilityTarget(0)).toThrow(RangeError);
      expect(() => validateAvailabilityTarget(-5)).toThrow(RangeError);
      expect(() => validateAvailabilityTarget(100)).toThrow(RangeError);
      expect(() => validateAvailabilityTarget(105)).toThrow(RangeError);
    });
  });

  describe('validateRequestCounts', () => {
    it('should accept valid non-negative counts with failed <= total', () => {
      expect(() => validateRequestCounts(1000, 10)).not.toThrow();
      expect(() => validateRequestCounts(0, 0)).not.toThrow();
      expect(() => validateRequestCounts(50, 50)).not.toThrow();
    });

    it('should reject non-integer or negative inputs', () => {
      expect(() => validateRequestCounts(-1, 0)).toThrow(TypeError);
      expect(() => validateRequestCounts(100, -2)).toThrow(TypeError);
      expect(() => validateRequestCounts(10.5, 2)).toThrow(TypeError);
    });

    it('should reject when failed requests exceed total requests', () => {
      expect(() => validateRequestCounts(10, 20)).toThrow(RangeError);
    });
  });

  describe('validateIncidentDurations', () => {
    it('should accept an array of positive numbers', () => {
      expect(() => validateIncidentDurations([10, 20, 30.5])).not.toThrow();
      expect(() => validateIncidentDurations([0])).not.toThrow();
    });

    it('should reject empty or non-array inputs', () => {
      // @ts-expect-error Testing invalid type
      expect(() => validateIncidentDurations(null)).toThrow(TypeError);
      expect(() => validateIncidentDurations([])).toThrow(TypeError);
    });

    it('should reject arrays with negative numbers or NaN', () => {
      expect(() => validateIncidentDurations([10, -5, 20])).toThrow(RangeError);
      expect(() => validateIncidentDurations([10, Number.NaN])).toThrow(RangeError);
    });
  });

  describe('validateWindowDays', () => {
    it('should calculate seconds correctly for positive integers', () => {
      const window30 = validateWindowDays(30);
      expect(window30.days).toBe(30);
      expect(window30.totalSeconds).toBe(30 * 86400);
    });

    it('should reject non-positive or non-integer window days', () => {
      expect(() => validateWindowDays(0)).toThrow(RangeError);
      expect(() => validateWindowDays(-1)).toThrow(RangeError);
      expect(() => validateWindowDays(2.5)).toThrow(RangeError);
    });
  });
});

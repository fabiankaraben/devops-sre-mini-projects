import { describe, it, expect } from 'vitest';
import { calculateAllowedDowntime, calculateErrorBudget, calculateBurnRate } from '../src/calculator.js';
import { formatMarkdownReport, formatJsonReport } from '../src/formatter.js';

describe('SRE Formatter Utilities', () => {
  const downtime = calculateAllowedDowntime(99.9, 30);
  const budget = calculateErrorBudget(99.9, 1000000, 200);
  const burnRate = calculateBurnRate(20, 24, 30);

  describe('formatMarkdownReport', () => {
    it('should generate a markdown table containing service name and status badge', () => {
      const md = formatMarkdownReport(
        { serviceName: 'OrderService', environment: 'Production' },
        downtime,
        budget,
        burnRate
      );

      expect(md).toContain('# SRE Availability & SLO Report: OrderService');
      expect(md).toContain('🟢 HEALTHY');
      expect(md).toContain('| **Availability Target** | `99.9%` | `99.98%`');
      expect(md).toContain('| **Total Requests** | 1,000,000 |');
    });

    it('should display EXHAUSTED badge when budget is depleted', () => {
      const exhaustedBudget = calculateErrorBudget(99.9, 10000, 50);
      const md = formatMarkdownReport(
        { serviceName: 'BillingAPI' },
        downtime,
        exhaustedBudget
      );

      expect(md).toContain('🔴 EXHAUSTED');
    });

    it('should use default fallback values if serviceName is empty or burnRate omitted', () => {
      const md = formatMarkdownReport(
        // @ts-expect-error Testing fallback
        { serviceName: '' },
        downtime,
        budget
      );
      expect(md).toContain('Unknown-Service');
      expect(md).toContain('N/A');
    });
  });

  describe('formatJsonReport', () => {
    it('should return valid parsable JSON matching the input telemetry', () => {
      const jsonStr = formatJsonReport(
        { serviceName: 'AuthService', environment: 'Staging' },
        downtime,
        budget,
        burnRate
      );

      const parsed = JSON.parse(jsonStr);
      expect(parsed.metadata.service).toBe('AuthService');
      expect(parsed.metadata.environment).toBe('Staging');
      expect(parsed.downtime.targetAvailabilityPercent).toBe(99.9);
      expect(parsed.budget.actualAvailabilityPercent).toBe(99.98);
      expect(parsed.burnRate.burnRate).toBeDefined();
    });

    it('should handle default options when environment and burnRate are omitted', () => {
      const jsonStr = formatJsonReport(
        { serviceName: 'NotificationService' },
        downtime,
        budget
      );
      const parsed = JSON.parse(jsonStr);
      expect(parsed.metadata.environment).toBe('Production');
      expect(parsed.burnRate).toBeNull();
    });
  });
});

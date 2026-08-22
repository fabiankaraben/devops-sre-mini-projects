/**
 * SRE Metrics Utility - Main Entrypoint & Public Exports
 */

export * from './validator.js';
export * from './calculator.js';
export * from './formatter.js';

import {
  calculateAllowedDowntime,
  calculateErrorBudget,
  calculateBurnRate,
  calculateMTTR,
} from './calculator.js';
import { formatMarkdownReport } from './formatter.js';

/**
 * Convenience runner for quick CLI demonstration.
 */
export function runDemo(): void {
  const targetAvailability = 99.9; // Three nines
  const totalRequests = 1000000;
  const failedRequests = 250;

  const downtime = calculateAllowedDowntime(targetAvailability, 30);
  const budget = calculateErrorBudget(targetAvailability, totalRequests, failedRequests);
  const burnRate = calculateBurnRate(budget.consumedBudgetPercent, 24, 30);
  const mttr = calculateMTTR([12, 15, 8, 22, 5]);

  const report = formatMarkdownReport(
    { serviceName: 'PaymentGateway', environment: 'Production' },
    downtime,
    budget,
    burnRate
  );

  console.log(report);
  console.log(`\nAverage MTTR across incidents: ${mttr} minutes`);
}

// Execute demo if executed directly
if (process.argv[1] && process.argv[1].endsWith('index.js')) {
  runDemo();
}

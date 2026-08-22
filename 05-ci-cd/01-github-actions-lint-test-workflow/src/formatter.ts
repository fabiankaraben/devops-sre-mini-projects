/**
 * SRE Metric Formatting Utilities (Markdown & JSON Report Generation)
 */

import { DowntimeBudget, ErrorBudgetStatus, BurnRateResult } from './calculator.js';

export interface SLAReportOptions {
  serviceName: string;
  environment?: string;
  timestamp?: string;
}

/**
 * Formats a comprehensive Markdown summary table of SRE SLO metrics.
 */
export function formatMarkdownReport(
  options: SLAReportOptions,
  downtime: DowntimeBudget,
  budget: ErrorBudgetStatus,
  burnRate?: BurnRateResult
): string {
  const serviceName = options.serviceName || 'Unknown-Service';
  const environment = options.environment || 'Production';
  const timestamp = options.timestamp || new Date().toISOString();

  const statusBadge = budget.isBudgetExhausted ? '🔴 EXHAUSTED' : '🟢 HEALTHY';
  const burnStatus = burnRate ? `\`${burnRate.burnRate}x\` (${burnRate.severity})` : 'N/A';

  return `# SRE Availability & SLO Report: ${serviceName}

- **Environment**: ${environment}
- **Generated At**: ${timestamp}
- **Status**: ${statusBadge}

## 🎯 Target vs Actual Availability

| Metric | Target | Actual | Delta |
| :--- | :--- | :--- | :--- |
| **Availability Target** | \`${downtime.targetAvailabilityPercent}%\` | \`${budget.actualAvailabilityPercent}%\` | \`${(budget.actualAvailabilityPercent - downtime.targetAvailabilityPercent).toFixed(4)}%\` |
| **Allowed Downtime (${downtime.windowDays}d)** | \`${downtime.allowedDowntimeMinutes} min\` | - | - |

## 📊 Error Budget Breakdown

| Parameter | Value |
| :--- | :--- |
| **Total Requests** | ${budget.totalRequests.toLocaleString()} |
| **Successful Requests** | ${budget.successfulRequests.toLocaleString()} |
| **Failed Requests** | ${budget.failedRequests.toLocaleString()} |
| **Total Allowed Errors** | ${budget.totalAllowedErrors.toLocaleString()} |
| **Remaining Allowed Errors** | ${budget.remainingAllowedErrors.toLocaleString()} |
| **Budget Consumed** | \`${budget.consumedBudgetPercent}%\` |
| **Current Burn Rate** | ${burnStatus} |
`;
}

/**
 * Formats SRE metric status as structured JSON string.
 */
export function formatJsonReport(
  options: SLAReportOptions,
  downtime: DowntimeBudget,
  budget: ErrorBudgetStatus,
  burnRate?: BurnRateResult
): string {
  return JSON.stringify(
    {
      metadata: {
        service: options.serviceName,
        environment: options.environment || 'Production',
        timestamp: options.timestamp || new Date().toISOString(),
      },
      downtime,
      budget,
      burnRate: burnRate || null,
    },
    null,
    2
  );
}

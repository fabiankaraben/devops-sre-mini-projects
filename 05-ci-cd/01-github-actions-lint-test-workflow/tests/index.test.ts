import { describe, it, expect, vi } from 'vitest';
import { runDemo, calculateAllowedDowntime, calculateErrorBudget } from '../src/index.js';

describe('Index Entrypoint & Exports', () => {
  it('should export all calculator and validator utilities', () => {
    expect(calculateAllowedDowntime).toBeDefined();
    expect(calculateErrorBudget).toBeDefined();
  });

  it('should execute runDemo without errors and log to stdout', () => {
    const consoleSpy = vi.spyOn(console, 'log').mockImplementation(() => {});
    expect(() => runDemo()).not.toThrow();
    expect(consoleSpy).toHaveBeenCalled();
    consoleSpy.mockRestore();
  });
});

import { describe, it, expect, vi } from 'vitest';
import { runDemo, parseCommitMessage, calculateNextRelease } from '../src/index.js';

describe('Index Entrypoint and Exports', () => {
  it('should export all parser and calculator functions', () => {
    expect(parseCommitMessage).toBeDefined();
    expect(calculateNextRelease).toBeDefined();
  });

  it('should run CLI demo without error and write to stdout', () => {
    const consoleSpy = vi.spyOn(console, 'log').mockImplementation(() => {});
    expect(() => runDemo()).not.toThrow();
    expect(consoleSpy).toHaveBeenCalled();
    consoleSpy.mockRestore();
  });
});

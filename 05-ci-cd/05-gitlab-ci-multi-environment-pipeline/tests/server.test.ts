import { describe, it, expect } from 'vitest';
import { server } from '../src/server.js';

describe('Server Bootstrap', () => {
  it('should export an instantiated http.Server', () => {
    expect(server).toBeDefined();
    expect(typeof server.listen).toBe('function');
  });
});

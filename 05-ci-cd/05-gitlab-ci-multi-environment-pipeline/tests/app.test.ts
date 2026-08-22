import { describe, it, expect, vi } from 'vitest';
import { handleRequest, createConfig, AppConfig } from '../src/app.js';
import { IncomingMessage, ServerResponse } from 'http';

function createMockResponse(): { res: ServerResponse; getOutput: () => string; getStatus: () => number } {
  let statusCode = 200;
  let body = '';
  const headers: Record<string, string> = {};

  const res = {
    statusCode: 200,
    setHeader: vi.fn((k: string, v: string) => {
      headers[k] = v;
    }),
    end: vi.fn((data: string) => {
      body = data;
    }),
  } as unknown as ServerResponse;

  Object.defineProperty(res, 'statusCode', {
    get: () => statusCode,
    set: (val: number) => {
      statusCode = val;
    },
  });

  return {
    res,
    getOutput: () => body,
    getStatus: () => statusCode,
  };
}

describe('Environment-Aware App Handlers', () => {
  const stagingConfig: AppConfig = {
    serviceName: 'test-service',
    version: '1.2.0',
    environment: 'staging',
    commitSha: 'sha-abc1234',
    port: 8091,
  };

  const prodConfig: AppConfig = {
    serviceName: 'test-service',
    version: '1.2.0',
    environment: 'production',
    commitSha: 'sha-abc1234',
    port: 8092,
  };

  it('should handle root path GET / for staging environment', () => {
    const req = { url: '/', headers: { host: 'localhost:8091' } } as IncomingMessage;
    const { res, getOutput, getStatus } = createMockResponse();

    handleRequest(req, res, Date.now(), stagingConfig);

    expect(getStatus()).toBe(200);
    const parsed = JSON.parse(getOutput());
    expect(parsed.environment).toBe('staging');
    expect(parsed.version).toBe('1.2.0');
    expect(parsed.status).toBe('running');
  });

  it('should handle GET /healthz and report healthy status', () => {
    const req = { url: '/healthz', headers: { host: 'localhost:8091' } } as IncomingMessage;
    const { res, getOutput, getStatus } = createMockResponse();

    handleRequest(req, res, Date.now() - 5000, stagingConfig);

    expect(getStatus()).toBe(200);
    const parsed = JSON.parse(getOutput());
    expect(parsed.status).toBe('healthy');
    expect(parsed.uptime_seconds).toBeGreaterThanOrEqual(5);
  });

  it('should handle GET /info for production environment', () => {
    const req = { url: '/info', headers: { host: 'localhost:8092' } } as IncomingMessage;
    const { res, getOutput, getStatus } = createMockResponse();

    handleRequest(req, res, Date.now(), prodConfig);

    expect(getStatus()).toBe(200);
    const parsed = JSON.parse(getOutput());
    expect(parsed.environment).toBe('production');
    expect(parsed.commit_sha).toBe('sha-abc1234');
    expect(parsed.port).toBe(8092);
  });

  it('should handle GET /version', () => {
    const req = { url: '/version', headers: { host: 'localhost:8092' } } as IncomingMessage;
    const { res, getOutput, getStatus } = createMockResponse();

    handleRequest(req, res, Date.now(), prodConfig);

    expect(getStatus()).toBe(200);
    const parsed = JSON.parse(getOutput());
    expect(parsed.version).toBe('1.2.0');
  });

  it('should return 404 for unknown routes', () => {
    const req = { url: '/non-existent-route', headers: { host: 'localhost:8091' } } as IncomingMessage;
    const { res, getOutput, getStatus } = createMockResponse();

    handleRequest(req, res, Date.now(), stagingConfig);

    expect(getStatus()).toBe(404);
    const parsed = JSON.parse(getOutput());
    expect(parsed.error).toBe('Not Found');
  });

  it('should default to environment variables in createConfig', () => {
    const config = createConfig();
    expect(config.serviceName).toBeDefined();
    expect(config.port).toBeGreaterThan(0);
  });
});

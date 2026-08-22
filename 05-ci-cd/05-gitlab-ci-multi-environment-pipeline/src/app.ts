/**
 * Environment-Aware Cloud-Native HTTP Request Handler
 */

import { IncomingMessage, ServerResponse } from 'http';

export interface AppConfig {
  serviceName: string;
  version: string;
  environment: string;
  commitSha: string;
  port: number;
}

export function createConfig(): AppConfig {
  return {
    serviceName: process.env.SERVICE_NAME || 'multi-env-delivery-service',
    version: process.env.APP_VERSION || '1.0.0',
    environment: process.env.APP_ENV || 'staging',
    commitSha: process.env.CI_COMMIT_SHA || 'dev-local',
    port: parseInt(process.env.PORT || '8080', 10),
  };
}

export function handleRequest(
  req: IncomingMessage,
  res: ServerResponse,
  startTime = Date.now(),
  config = createConfig()
): void {
  const url = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);
  const pathname = url.pathname;

  res.setHeader('Content-Type', 'application/json');
  res.setHeader('X-Environment', config.environment);
  res.setHeader('X-Service-Version', config.version);

  if (pathname === '/') {
    res.statusCode = 200;
    res.end(
      JSON.stringify({
        message: 'GitLab CI Multi-Environment Delivery Service',
        environment: config.environment,
        version: config.version,
        service: config.serviceName,
        status: 'running',
      })
    );
    return;
  }

  if (pathname === '/healthz') {
    res.statusCode = 200;
    res.end(
      JSON.stringify({
        status: 'healthy',
        environment: config.environment,
        uptime_seconds: Math.floor((Date.now() - startTime) / 1000),
        timestamp: new Date().toISOString(),
      })
    );
    return;
  }

  if (pathname === '/info') {
    res.statusCode = 200;
    res.end(
      JSON.stringify({
        service: config.serviceName,
        environment: config.environment,
        version: config.version,
        commit_sha: config.commitSha,
        port: config.port,
        node_version: process.version,
        timestamp: new Date().toISOString(),
      })
    );
    return;
  }

  if (pathname === '/version') {
    res.statusCode = 200;
    res.end(
      JSON.stringify({
        version: config.version,
        commit_sha: config.commitSha,
      })
    );
    return;
  }

  res.statusCode = 404;
  res.end(
    JSON.stringify({
      error: 'Not Found',
      path: pathname,
    })
  );
}

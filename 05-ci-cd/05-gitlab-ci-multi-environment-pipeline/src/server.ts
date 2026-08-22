/**
 * Server Bootstrap and Graceful Shutdown Handler
 */

import { createServer } from 'http';
import { handleRequest, createConfig } from './app.js';

const config = createConfig();
const startTime = Date.now();

export const server = createServer((req, res) => {
  handleRequest(req, res, startTime, config);
});

if (process.env.NODE_ENV !== 'test') {
  server.listen(config.port, () => {
    console.log(
      `[${config.environment.toUpperCase()}] Server running at http://0.0.0.0:${config.port} (v${config.version})`
    );
  });

  const shutdown = (): void => {
    console.log('\nShutting down server gracefully...');
    server.close(() => {
      console.log('Server closed successfully.');
      process.exit(0);
    });
  };

  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

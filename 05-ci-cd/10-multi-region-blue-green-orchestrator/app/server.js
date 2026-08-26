const http = require("http");
const os = require("os");

const PORT = parseInt(process.env.PORT || "3000", 10);
const APP_COLOR = (process.env.APP_COLOR || "blue").toLowerCase();
const APP_VERSION = process.env.APP_VERSION || "v1.0.0";
const REGION_NAME = process.env.REGION_NAME || "us-east";
let SIMULATE_FAILURE = process.env.SIMULATE_FAILURE === "true";

const server = http.createServer((req, res) => {
    const url = req.url;
    const failureHeader = req.headers["x-simulate-failure"] === "true";

    // Toggle runtime failure simulation if requested via query or header
    if (url.startsWith("/admin/simulate-failure")) {
        const urlParams = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
        const enable = urlParams.searchParams.get("enable");
        if (enable !== null) {
            SIMULATE_FAILURE = enable === "true";
        }
        res.writeHead(200, { "Content-Type": "application/json" });
        return res.end(JSON.stringify({
            simulateFailure: SIMULATE_FAILURE,
            color: APP_COLOR,
            region: REGION_NAME
        }));
    }

    if (url === "/health" || url === "/livez") {
        if (SIMULATE_FAILURE || failureHeader) {
            res.writeHead(500, { "Content-Type": "application/json" });
            return res.end(JSON.stringify({
                status: "DOWN",
                error: "Simulated health failure",
                color: APP_COLOR,
                region: REGION_NAME,
                version: APP_VERSION
            }));
        }

        res.writeHead(200, { "Content-Type": "application/json" });
        return res.end(JSON.stringify({
            status: "UP",
            color: APP_COLOR,
            version: APP_VERSION,
            region: REGION_NAME,
            uptimeSeconds: Math.floor(process.uptime()),
            timestamp: new Date().toISOString()
        }));
    }

    if (url === "/smoke-test") {
        if (SIMULATE_FAILURE || failureHeader) {
            res.writeHead(500, { "Content-Type": "application/json" });
            return res.end(JSON.stringify({
                smokeTest: "FAILED",
                error: "Smoke test assertion failed: critical dependency unreachable",
                color: APP_COLOR,
                region: REGION_NAME,
                version: APP_VERSION,
                timestamp: new Date().toISOString()
            }));
        }

        res.writeHead(200, { "Content-Type": "application/json" });
        return res.end(JSON.stringify({
            smokeTest: "PASSED",
            databaseCheck: "OK",
            cacheCheck: "OK",
            latencyMs: 1.2,
            color: APP_COLOR,
            region: REGION_NAME,
            version: APP_VERSION,
            timestamp: new Date().toISOString()
        }));
    }

    if (url === "/api/info" || url === "/api/version") {
        res.writeHead(200, { "Content-Type": "application/json" });
        return res.end(JSON.stringify({
            app: "order-service",
            color: APP_COLOR,
            version: APP_VERSION,
            region: REGION_NAME,
            hostname: os.hostname(),
            timestamp: new Date().toISOString()
        }));
    }

    // Default HTML dashboard
    const isBlue = APP_COLOR === "blue";
    const bgGradient = isBlue 
        ? "linear-gradient(135deg, #1e3a8a 0%, #0f172a 100%)" 
        : "linear-gradient(135deg, #065f46 0%, #0f172a 100%)";
    const accentColor = isBlue ? "#3b82f6" : "#10b981";

    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    res.end(`<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Multi-Region Deployment (${APP_COLOR.toUpperCase()})</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: ${bgGradient}; color: #f8fafc; padding: 2rem; margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center; }
    .card { width: 100%; max-width: 540px; background: rgba(30, 41, 59, 0.85); backdrop-filter: blur(10px); border-radius: 16px; padding: 2.5rem; border: 1px solid rgba(255,255,255,0.1); box-shadow: 0 20px 40px rgba(0,0,0,0.6); }
    .badge-row { display: flex; gap: 0.5rem; margin-bottom: 1rem; }
    .badge { padding: 0.35rem 0.85rem; border-radius: 9999px; font-weight: bold; font-size: 0.85rem; text-transform: uppercase; letter-spacing: 0.05em; }
    .badge-color { background: ${accentColor}; color: #ffffff; }
    .badge-region { background: #475569; color: #f1f5f9; }
    h1 { margin: 0 0 0.5rem 0; font-size: 1.85rem; }
    p.sub { color: #94a3b8; margin: 0 0 1.5rem 0; font-size: 0.95rem; }
    .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; margin-bottom: 1.5rem; }
    .metric-box { background: rgba(15, 23, 42, 0.6); border-radius: 8px; padding: 1rem; border: 1px solid #334155; }
    .metric-label { font-size: 0.75rem; text-transform: uppercase; color: #94a3b8; letter-spacing: 0.05em; }
    .metric-val { font-size: 1.25rem; font-weight: bold; font-family: monospace; margin-top: 0.25rem; color: #f8fafc; }
    .footer { font-size: 0.8rem; color: #64748b; text-align: center; border-top: 1px solid #334155; padding-top: 1rem; }
  </style>
</head>
<body>
  <div class="card">
    <div class="badge-row">
      <span class="badge badge-color">${APP_COLOR} ENVIRONMENT</span>
      <span class="badge badge-region">REGION: ${REGION_NAME.toUpperCase()}</span>
    </div>
    <h1>Multi-Region Service Live</h1>
    <p class="sub">Zero-Downtime Blue-Green Architecture with Automated Smoke Testing</p>

    <div class="grid">
      <div class="metric-box">
        <div class="metric-label">Active Version</div>
        <div class="metric-val">${APP_VERSION}</div>
      </div>
      <div class="metric-box">
        <div class="metric-label">Target Region</div>
        <div class="metric-val">${REGION_NAME}</div>
      </div>
      <div class="metric-box">
        <div class="metric-label">Deployment Slot</div>
        <div class="metric-val">${APP_COLOR.toUpperCase()}</div>
      </div>
      <div class="metric-box">
        <div class="metric-label">Host Node</div>
        <div class="metric-val">${os.hostname().substring(0, 12)}</div>
      </div>
    </div>

    <div class="footer">
      DevOps SRE Multi-Region Blue-Green Orchestration Suite
    </div>
  </div>
</body>
</html>`);
});

server.listen(PORT, "0.0.0.0", () => {
    console.log(`[SERVICE] Running [${APP_COLOR.toUpperCase()}] version ${APP_VERSION} on port ${PORT} (Region: ${REGION_NAME})`);
});

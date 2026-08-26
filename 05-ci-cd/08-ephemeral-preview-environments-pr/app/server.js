const http = require("http");
const os = require("os");

const PORT = process.env.PORT || 3000;
const PR_NUMBER = process.env.PR_NUMBER || "unknown";
const COMMIT_SHA = process.env.COMMIT_SHA || "HEAD";
const BRANCH_NAME = process.env.BRANCH_NAME || "feature/preview";
const APP_VERSION = process.env.APP_VERSION || "v1.0.0";
const FEATURE_FLAG_NEW_UI = process.env.FEATURE_FLAG_NEW_UI === "true";

const server = http.createServer((req, res) => {
    const url = req.url;

    if (url === "/health" || url === "/livez") {
        res.writeHead(200, { "Content-Type": "application/json" });
        return res.end(JSON.stringify({
            status: "UP",
            uptimeSeconds: Math.floor(process.uptime()),
            timestamp: new Date().toISOString(),
            pod: os.hostname()
        }));
    }

    if (url === "/api/info") {
        res.writeHead(200, { "Content-Type": "application/json" });
        return res.end(JSON.stringify({
            prNumber: PR_NUMBER,
            commitSha: COMMIT_SHA,
            branchName: BRANCH_NAME,
            version: APP_VERSION,
            featureFlagNewUi: FEATURE_FLAG_NEW_UI,
            podName: os.hostname(),
            nodeVersion: process.version
        }));
    }

    // Default HTML dashboard
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    res.end(`<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Preview Environment - PR #${PR_NUMBER}</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background: #0f172a; color: #f8fafc; padding: 2rem; margin: 0; }
    .card { max-width: 600px; margin: 0 auto; background: #1e293b; border-radius: 12px; padding: 2rem; border: 1px solid #334155; box-shadow: 0 10px 25px rgba(0,0,0,0.5); }
    .badge { display: inline-block; padding: 0.25rem 0.75rem; border-radius: 9999px; font-weight: bold; font-size: 0.875rem; background: #3b82f6; color: #ffffff; }
    .badge.feature { background: #10b981; }
    h1 { margin-top: 0.5rem; font-size: 1.75rem; }
    .meta-row { display: flex; justify-content: space-between; padding: 0.5rem 0; border-bottom: 1px solid #334155; font-size: 0.9rem; }
    .meta-label { color: #94a3b8; }
    .meta-val { font-family: monospace; font-weight: bold; }
    .footer { margin-top: 1.5rem; font-size: 0.8rem; color: #64748b; text-align: center; }
  </style>
</head>
<body>
  <div class="card">
    <span class="badge">🚀 PR Preview Environment</span>
    ${FEATURE_FLAG_NEW_UI ? '<span class="badge feature">✨ New UI Enabled</span>' : ''}
    <h1>PR #${PR_NUMBER}: ${BRANCH_NAME}</h1>
    <p>This is an on-demand ephemeral review application dynamically provisioned on Kubernetes.</p>
    
    <div class="meta-row">
      <span class="meta-label">PR Number</span>
      <span class="meta-val">#${PR_NUMBER}</span>
    </div>
    <div class="meta-row">
      <span class="meta-label">Branch</span>
      <span class="meta-val">${BRANCH_NAME}</span>
    </div>
    <div class="meta-row">
      <span class="meta-label">Commit SHA</span>
      <span class="meta-val">${COMMIT_SHA}</span>
    </div>
    <div class="meta-row">
      <span class="meta-label">Version</span>
      <span class="meta-val">${APP_VERSION}</span>
    </div>
    <div class="meta-row">
      <span class="meta-label">Pod Hostname</span>
      <span class="meta-val">${os.hostname()}</span>
    </div>

    <div class="footer">
      Generated automatically by DevOps SRE Ephemeral Preview Pipeline
    </div>
  </div>
</body>
</html>`);
});

server.listen(PORT, "0.0.0.0", () => {
    console.log(`[PREVIEW-APP] Server listening on http://0.0.0.0:${PORT} (PR: #${PR_NUMBER}, Version: ${APP_VERSION})`);
});

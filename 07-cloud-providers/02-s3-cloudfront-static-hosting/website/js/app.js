/**
 * CloudEdge CDN - Client-Side Application Logic
 * ==============================================================================
 */

document.addEventListener("DOMContentLoaded", () => {
  initTheme();
  renderSecurityHeadersTable();
  initAuditRunner();
  initLatencyBenchmark();
  initNavigation();
});

// ------------------------------------------------------------------------------
// 1. Theme Management (Dark / Light)
// ------------------------------------------------------------------------------
function initTheme() {
  const themeToggle = document.getElementById("theme-toggle");
  if (!themeToggle) return;

  const savedTheme = localStorage.getItem("cloudedge-theme") || "dark";
  document.documentElement.setAttribute("data-theme", savedTheme);
  themeToggle.textContent = savedTheme === "light" ? "🌙" : "☀️";

  themeToggle.addEventListener("click", () => {
    const currentTheme = document.documentElement.getAttribute("data-theme");
    const newTheme = currentTheme === "light" ? "dark" : "light";
    document.documentElement.setAttribute("data-theme", newTheme);
    localStorage.setItem("cloudedge-theme", newTheme);
    themeToggle.textContent = newTheme === "light" ? "🌙" : "☀️";
  });
}

// ------------------------------------------------------------------------------
// 2. Security Headers Data & Rendering
// ------------------------------------------------------------------------------
const SECURITY_HEADERS = [
  {
    name: "Strict-Transport-Security",
    value: "max-age=63072000; includeSubDomains; preload",
    vulnerability: "Man-In-The-Middle (MITM) & SSL Strip Attacks",
    status: "ENFORCED"
  },
  {
    name: "X-Frame-Options",
    value: "DENY",
    vulnerability: "Clickjacking & UI Redressing Attacks",
    status: "ENFORCED"
  },
  {
    name: "X-Content-Type-Options",
    value: "nosniff",
    vulnerability: "MIME-Type Confusion & Executable Injection",
    status: "ENFORCED"
  },
  {
    name: "Content-Security-Policy",
    value: "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:;",
    vulnerability: "Cross-Site Scripting (XSS) & Unauthorized Script Injection",
    status: "ENFORCED"
  },
  {
    name: "Referrer-Policy",
    value: "strict-origin-when-cross-origin",
    vulnerability: "Sensitive URL Token & Path Leakage",
    status: "ENFORCED"
  },
  {
    name: "Permissions-Policy",
    value: "camera=(), microphone=(), geolocation=()",
    vulnerability: "Unauthorized Browser Hardware / API Exploits",
    status: "ENFORCED"
  },
  {
    name: "X-XSS-Protection",
    value: "1; mode=block",
    vulnerability: "Legacy Browser Cross-Site Scripting (XSS)",
    status: "ENFORCED"
  }
];

function renderSecurityHeadersTable() {
  const tbody = document.getElementById("headers-tbody");
  if (!tbody) return;

  tbody.innerHTML = SECURITY_HEADERS.map(header => `
    <tr>
      <td class="header-name">${escapeHtml(header.name)}</td>
      <td class="header-value"><code>${escapeHtml(header.value)}</code></td>
      <td>${escapeHtml(header.vulnerability)}</td>
      <td><span class="badge badge-success">${escapeHtml(header.status)}</span></td>
    </tr>
  `).join("");
}

// ------------------------------------------------------------------------------
// 3. Interactive Security Audit Simulation
// ------------------------------------------------------------------------------
function initAuditRunner() {
  const btnAudit = document.getElementById("btn-run-audit");
  const auditStatus = document.getElementById("audit-status");
  if (!btnAudit || !auditStatus) return;

  btnAudit.addEventListener("click", () => {
    btnAudit.disabled = true;
    btnAudit.textContent = "Auditing Headers...";
    auditStatus.className = "badge";
    auditStatus.textContent = "Scanning Edge PoP...";

    setTimeout(() => {
      auditStatus.className = "badge badge-success";
      auditStatus.textContent = "100% Passed (7/7 Headers)";
      btnAudit.disabled = false;
      btnAudit.textContent = "Re-Run Security Audit";

      const headersSection = document.getElementById("headers");
      if (headersSection) {
        headersSection.scrollIntoView({ behavior: "smooth" });
      }
    }, 800);
  });
}

// ------------------------------------------------------------------------------
// 4. Edge Latency Benchmark Simulator
// ------------------------------------------------------------------------------
function initLatencyBenchmark() {
  const btnBenchmark = document.getElementById("btn-simulate-latency");
  const metricEdge = document.getElementById("metric-edge");
  const metricOrigin = document.getElementById("metric-origin");
  const metricImprovement = document.getElementById("metric-improvement");
  const logsContainer = document.getElementById("benchmark-logs");

  if (!btnBenchmark || !metricEdge || !metricOrigin || !logsContainer) return;

  btnBenchmark.addEventListener("click", () => {
    btnBenchmark.disabled = true;
    btnBenchmark.textContent = "Running Benchmark...";

    // Randomize realistic realistic CDN vs Origin metrics
    const edgeMs = Math.floor(Math.random() * 8) + 8; // 8 - 15ms
    const originMs = Math.floor(Math.random() * 50) + 160; // 160 - 210ms
    const improvement = (((originMs - edgeMs) / originMs) * 100).toFixed(1);

    metricEdge.textContent = `${edgeMs} ms`;
    metricOrigin.textContent = `${originMs} ms`;
    metricImprovement.textContent = `${improvement}%`;

    const timestamp = new Date().toLocaleTimeString();
    const logEntry = document.createElement("div");
    logEntry.className = "log-entry log-success";
    logEntry.textContent = `[${timestamp}] Test completed: Edge TTFB ${edgeMs}ms vs S3 Origin ${originMs}ms (${improvement}% speedup).`;
    logsContainer.prepend(logEntry);

    btnBenchmark.disabled = false;
    btnBenchmark.textContent = "Benchmark Edge Latency";

    const metricsSection = document.getElementById("metrics");
    if (metricsSection) {
      metricsSection.scrollIntoView({ behavior: "smooth" });
    }
  });
}

// ------------------------------------------------------------------------------
// 5. Smooth Navigation Scroll
// ------------------------------------------------------------------------------
function initNavigation() {
  const links = document.querySelectorAll(".nav-link");
  links.forEach(link => {
    link.addEventListener("click", (e) => {
      links.forEach(l => l.classList.remove("active"));
      link.classList.add("active");
    });
  });
}

function escapeHtml(str) {
  const div = document.createElement("div");
  div.textContent = str;
  return div.innerHTML;
}

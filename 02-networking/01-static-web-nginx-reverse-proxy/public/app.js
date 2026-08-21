/**
 * Nginx Reverse Proxy & Static Cache Hub - Client Logic
 */

document.addEventListener("DOMContentLoaded", () => {
    // Initial health check probe to update navbar status pill
    checkBackendHealth();
    // Default load /api/info
    testEndpoint("/api/info");
});

/**
 * Check backend health via /api/health to update navbar indicator
 */
async function checkBackendHealth() {
    const dot = document.getElementById("backend-dot");
    const text = document.getElementById("backend-status-text");

    try {
        const res = await fetch("/api/health");
        if (res.ok) {
            dot.className = "dot dot-green";
            text.textContent = "Online (Proxied)";
        } else {
            dot.className = "dot dot-yellow";
            text.textContent = `Degraded (${res.status})`;
        }
    } catch (err) {
        dot.className = "dot dot-red";
        text.textContent = "Offline / Unreachable";
    }
}

/**
 * Send request to an endpoint and display latency, headers, and body
 */
async function testEndpoint(path) {
    const startTime = performance.now();
    const resStatus = document.getElementById("res-status");
    const resTime = document.getElementById("res-time");
    const resEncoding = document.getElementById("res-encoding");
    const resCache = document.getElementById("res-cache");
    const resBody = document.getElementById("response-body");
    const headersTableBody = document.getElementById("headers-table-body");

    resBody.textContent = `Fetching GET ${path}...`;

    try {
        const response = await fetch(path);
        const duration = Math.round(performance.now() - startTime);

        // Update status badge
        resStatus.textContent = `${response.status} ${response.statusText}`;
        resStatus.className = "meta-value badge-status";
        if (response.status >= 200 && response.status < 300) {
            resStatus.classList.add("badge-2xx");
        } else if (response.status >= 400 && response.status < 500) {
            resStatus.classList.add("badge-4xx");
        } else {
            resStatus.classList.add("badge-5xx");
        }

        // Update metadata bar
        resTime.textContent = `${duration} ms`;
        resEncoding.textContent = response.headers.get("content-encoding") || "none (identity)";
        resCache.textContent = response.headers.get("cache-control") || "none";

        // Read headers
        const headersList = [];
        response.headers.forEach((val, key) => {
            headersList.push({ key, val });
        });

        // Populate headers table
        if (headersList.length > 0) {
            headersTableBody.innerHTML = headersList
                .map(h => `<tr><td>${escapeHtml(h.key)}</td><td>${escapeHtml(h.val)}</td></tr>`)
                .join("");
        } else {
            headersTableBody.innerHTML = `<tr><td colspan="2" class="empty-msg">No accessible headers in response</td></tr>`;
        }

        // Read and format payload
        const contentType = response.headers.get("content-type") || "";
        let bodyContent = "";

        if (contentType.includes("application/json")) {
            const jsonData = await response.json();
            bodyContent = JSON.stringify(jsonData, null, 2);

            // Update proxy header breakdown tab if proxy_headers present in response
            if (jsonData.proxy_headers) {
                document.getElementById("proxy-hdr-xff").textContent = jsonData.proxy_headers.x_forwarded_for || "None";
                document.getElementById("proxy-hdr-xreal").textContent = jsonData.proxy_headers.x_real_ip || "None";
                document.getElementById("proxy-hdr-proto").textContent = jsonData.proxy_headers.x_forwarded_proto || "None";
                document.getElementById("proxy-hdr-host").textContent = jsonData.proxy_headers.host || "None";
            }
        } else {
            bodyContent = await response.text();
        }

        document.getElementById("proxy-hdr-by").textContent = response.headers.get("x-proxy-by") || "Nginx-Reverse-Proxy-MiniProject";
        resBody.textContent = bodyContent;

    } catch (err) {
        const duration = Math.round(performance.now() - startTime);
        resStatus.textContent = "Error";
        resStatus.className = "meta-value badge-status badge-5xx";
        resTime.textContent = `${duration} ms`;
        resEncoding.textContent = "-";
        resCache.textContent = "-";
        resBody.textContent = `Network / Fetch Error: ${err.message}`;
        headersTableBody.innerHTML = `<tr><td colspan="2" class="empty-msg">Failed to connect to proxy endpoint</td></tr>`;
    }
}

/**
 * Test static assets directly
 */
function testStaticAsset(assetPath) {
    testEndpoint(assetPath);
}

/**
 * Handle custom route user input
 */
function testCustomPath() {
    const input = document.getElementById("custom-path-input");
    const path = input.value.trim();
    if (path) {
        testEndpoint(path);
    }
}

/**
 * Switch tabs in the inspector card
 */
function switchTab(tabName) {
    document.querySelectorAll(".tab-btn").forEach(btn => btn.classList.remove("active"));
    document.querySelectorAll(".tab-pane").forEach(pane => pane.classList.remove("active"));

    const btn = document.getElementById(`tab-${tabName}-btn`);
    const pane = document.getElementById(`tab-${tabName}`);

    if (btn && pane) {
        btn.classList.add("active");
        pane.classList.add("active");
    }
}

/**
 * Helper to escape HTML characters
 */
function escapeHtml(str) {
    return str
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&#039;");
}

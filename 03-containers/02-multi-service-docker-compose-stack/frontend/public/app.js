/**
 * Multi-Service Docker Compose Stack Dashboard
 * Handles live health polling, stats monitoring, and CRUD operations.
 */

document.addEventListener('DOMContentLoaded', () => {
    // DOM Elements
    const btnRefresh = document.getElementById('btn-refresh');
    const btnFetchCache = document.getElementById('btn-fetch-cache');
    const formAddItem = document.getElementById('form-add-item');
    const itemsTableBody = document.getElementById('items-table-body');
    
    const statusApiDot = document.getElementById('status-api-dot');
    const statusRedisDot = document.getElementById('status-redis-dot');
    const statusPostgresDot = document.getElementById('status-postgres-dot');
    
    const latencyApi = document.getElementById('latency-api');
    const latencyRedis = document.getElementById('latency-redis');
    
    const cacheStatusBadge = document.getElementById('cache-status-badge');
    const statTotalItems = document.getElementById('stat-total-items');
    const statCachedKeys = document.getElementById('stat-cached-keys');
    const statLastLatency = document.getElementById('stat-last-latency');
    const statCacheSource = document.getElementById('stat-cache-source');

    // Fetch Health State of all downstream services
    async function checkHealth() {
        try {
            const start = performance.now();
            const res = await fetch('/api/health');
            const duration = Math.round(performance.now() - start);
            
            if (res.ok) {
                const data = await res.json();
                latencyApi.textContent = `${duration} ms`;
                statusApiDot.className = 'status-indicator status-ok';

                // Postgres Status
                if (data.dependencies?.postgres?.status === 'connected') {
                    statusPostgresDot.className = 'status-indicator status-ok';
                } else {
                    statusPostgresDot.className = 'status-indicator status-err';
                }

                // Redis Status
                if (data.dependencies?.redis?.status === 'connected') {
                    statusRedisDot.className = 'status-indicator status-ok';
                    latencyRedis.textContent = `${data.dependencies.redis.latency_ms} ms`;
                } else {
                    statusRedisDot.className = 'status-indicator status-err';
                    latencyRedis.textContent = 'Err';
                }
            } else {
                statusApiDot.className = 'status-indicator status-err';
                latencyApi.textContent = 'Err';
            }
        } catch (err) {
            console.error('Healthcheck error:', err);
            statusApiDot.className = 'status-indicator status-err';
            statusRedisDot.className = 'status-indicator status-err';
            statusPostgresDot.className = 'status-indicator status-err';
        }
    }

    // Fetch System & Database Stats
    async function fetchStats() {
        try {
            const res = await fetch('/api/stats');
            if (res.ok) {
                const data = await res.json();
                statTotalItems.textContent = data.database?.total_items ?? 0;
                statCachedKeys.textContent = data.cache?.cached_keys_count ?? 0;
            }
        } catch (err) {
            console.error('Stats fetch error:', err);
        }
    }

    // Fetch Items List (Demonstrates Cache-Aside Hit vs Miss)
    async function fetchItems() {
        try {
            const start = performance.now();
            const res = await fetch('/api/items');
            const duration = Math.round(performance.now() - start);
            statLastLatency.textContent = `${duration} ms`;

            if (res.ok) {
                const data = await res.json();
                const source = data.source || 'unknown';
                const isHit = (data.cache_status === 'HIT');

                // Update Cache Badge
                cacheStatusBadge.className = isHit ? 'cache-badge cache-hit' : 'cache-badge cache-miss';
                cacheStatusBadge.textContent = isHit ? `CACHE HIT (Redis • ${duration}ms)` : `CACHE MISS (Postgres DB • ${duration}ms)`;
                statCacheSource.textContent = source.toUpperCase();
                statTotalItems.textContent = data.count ?? 0;

                renderItems(data.items || []);
            } else {
                itemsTableBody.innerHTML = `<tr><td colspan="5" class="empty-state">Error fetching items.</td></tr>`;
            }
        } catch (err) {
            console.error('Fetch items error:', err);
            itemsTableBody.innerHTML = `<tr><td colspan="5" class="empty-state">Network error connecting to API.</td></tr>`;
        }
    }

    // Render Table Rows
    function renderItems(items) {
        if (!items || items.length === 0) {
            itemsTableBody.innerHTML = `<tr><td colspan="5" class="empty-state">No workload items found. Create one above!</td></tr>`;
            return;
        }

        itemsTableBody.innerHTML = items.map(item => {
            const dateStr = item.created_at ? new Date(item.created_at).toLocaleTimeString() : 'N/A';
            return `
                <tr>
                    <td><code>#${item.id}</code></td>
                    <td><strong>${escapeHtml(item.title)}</strong><br><small style="color:var(--text-dim)">${escapeHtml(item.description || '')}</small></td>
                    <td><span class="priority-badge priority-${item.priority}">${item.priority}</span></td>
                    <td>${dateStr}</td>
                    <td>
                        <button class="btn-danger-sm" onclick="deleteItem(${item.id})">Delete</button>
                    </td>
                </tr>
            `;
        }).join('');
    }

    // Escape HTML to prevent XSS
    function escapeHtml(str) {
        return str
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
            .replace(/"/g, "&quot;")
            .replace(/'/g, "&#039;");
    }

    // Add New Item
    formAddItem.addEventListener('submit', async (e) => {
        e.preventDefault();
        const title = document.getElementById('item-title').value;
        const description = document.getElementById('item-desc').value;
        const priority = document.getElementById('item-priority').value;

        try {
            const res = await fetch('/api/items', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: json.stringify({ title, description, priority })
            });

            if (res.ok) {
                formAddItem.reset();
                await fetchItems();
                await fetchStats();
            } else {
                const err = await res.json();
                alert(`Failed to add item: ${err.error || 'Unknown error'}`);
            }
        } catch (err) {
            console.error('Submit item error:', err);
            alert('Network error adding item.');
        }
    });

    // Delete Item
    window.deleteItem = async function(id) {
        if (!confirm(`Are you sure you want to delete item #${id}?`)) return;
        try {
            const res = await fetch(`/api/items/${id}`, { method: 'DELETE' });
            if (res.ok) {
                await fetchItems();
                await fetchStats();
            } else {
                alert('Failed to delete item.');
            }
        } catch (err) {
            console.error('Delete item error:', err);
        }
    };

    // Initial Load & Listeners
    btnRefresh.addEventListener('click', () => {
        checkHealth();
        fetchStats();
        fetchItems();
    });

    btnFetchCache.addEventListener('click', () => {
        fetchItems();
        fetchStats();
    });

    // Initial sync
    checkHealth();
    fetchStats();
    fetchItems();

    // Auto-polling health every 5 seconds
    setInterval(checkHealth, 5000);
});

/**
 * CloudOps Monitor — script.js
 * Fetches status.json every 30s and drives the entire dashboard UI.
 * Features: auto-refresh, error handling, progress bars, toast notifications,
 *           live clock, online/offline badge, last-updated timestamp.
 *
 * Data flow: monitor.sh → status.json → fetchStatus() → renderDashboard() → DOM
 *
 * Author: Shreenath Mehta
 */

/* ============================================================
   CONSTANTS
   ============================================================ */
const STATUS_URL      = 'status.json';  // relative path — same directory
const REFRESH_MS      = 30_000;         // auto-refresh interval (30 seconds)
const TOAST_DURATION  = 4_000;          // toast visible for 4 seconds
const WARN_THRESHOLD  = 85;             // % above which progress bars turn red

/* ============================================================
   STATE
   ============================================================ */
let retryInterval    = null;  // stores setInterval handle
let retryCountdown   = 30;    // countdown seconds shown in offline banner
let isOnline         = true;  // tracks current connection state

/* ============================================================
   1. LIVE CLOCK
   Updates the clock element every second.
   ============================================================ */
function startClock() {
  const clockEl = document.getElementById('live-clock');

  function tick() {
    const now = new Date();
    // Format: HH:MM:SS using locale (24h)
    clockEl.textContent = now.toLocaleTimeString('en-GB', {
      hour:   '2-digit',
      minute: '2-digit',
      second: '2-digit',
    });
  }

  tick(); // run immediately before first interval fires
  setInterval(tick, 1000);
}

/* ============================================================
   2. TOAST NOTIFICATIONS
   type: 'success' | 'error' | 'info'
   ============================================================ */
function showToast(message, type = 'info') {
  const container = document.getElementById('toast-container');

  // Create toast element
  const toast = document.createElement('div');
  toast.className = `toast toast--${type}`;
  toast.setAttribute('role', 'alert');

  // Icon per type (inline SVG)
  const icons = {
    success: `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="20 6 9 17 4 12"/></svg>`,
    error:   `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/></svg>`,
    info:    `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="10"/><line x1="12" y1="16" x2="12" y2="12"/><line x1="12" y1="8" x2="12.01" y2="8"/></svg>`,
  };

  toast.innerHTML = `${icons[type] || ''}<span>${message}</span>`;
  container.appendChild(toast);

  // Auto-remove after TOAST_DURATION
  setTimeout(() => {
    toast.classList.add('fade-out');
    toast.addEventListener('animationend', () => toast.remove());
  }, TOAST_DURATION);
}

/* ============================================================
   3. STATUS BADGE — toggle online/offline
   ============================================================ */
function setOnlineStatus(online) {
  const badge  = document.getElementById('status-badge');
  const text   = document.getElementById('status-text');
  const banner = document.getElementById('offline-banner');

  if (online) {
    badge.className  = 'status-badge status-online';
    text.textContent = 'ONLINE';
    banner.classList.add('hidden');
    badge.setAttribute('aria-label', 'Connection status: Online');
  } else {
    badge.className  = 'status-badge status-offline';
    text.textContent = 'OFFLINE';
    banner.classList.remove('hidden');
    badge.setAttribute('aria-label', 'Connection status: Offline');
  }

  isOnline = online;
}

/* ============================================================
   4. RETRY COUNTDOWN (shown in offline banner)
   ============================================================ */
function startRetryCountdown() {
  const countdownEl = document.getElementById('retry-countdown');
  retryCountdown = REFRESH_MS / 1000;

  const timer = setInterval(() => {
    retryCountdown -= 1;
    if (countdownEl) countdownEl.textContent = retryCountdown;
    if (retryCountdown <= 0) {
      clearInterval(timer);
      retryCountdown = REFRESH_MS / 1000;
    }
  }, 1000);
}

/* ============================================================
   5. PARSE HELPERS
   These convert the string values in status.json into numbers
   suitable for driving progress bars.
   ============================================================ */

/**
 * parseDiskPercent — extract integer from strings like "34%" or "34"
 * @param {string} val
 * @returns {number} 0-100
 */
function parseDiskPercent(val) {
  if (!val) return 0;
  return parseInt(val.replace('%', ''), 10) || 0;
}

/**
 * parseMemoryPercent — use memory_percent field directly if available,
 * otherwise calculate from "411Mi/911Mi" string.
 * @param {object} data — full status.json payload
 * @returns {number} 0-100
 */
function parseMemoryPercent(data) {
  // Prefer the pre-calculated field from monitor.sh
  if (data.memory_percent) {
    return parseInt(data.memory_percent, 10) || 0;
  }
  // Fallback: parse "XMi/YMi" string
  if (data.memory) {
    const parts = data.memory.split('/');
    if (parts.length === 2) {
      const used  = parseFloat(parts[0]);
      const total = parseFloat(parts[1]);
      if (!isNaN(used) && !isNaN(total) && total > 0) {
        return Math.round((used / total) * 100);
      }
    }
  }
  return 0;
}

/**
 * parseCPUPercent — use cpu_percent field (integer string).
 * @param {string} val
 * @returns {number} 0-100
 */
function parseCPUPercent(val) {
  return parseInt(val, 10) || 0;
}

/**
 * parseLoadAvg — split "0.15 0.10 0.08" into [1m, 5m, 15m] values.
 * @param {string} val
 * @returns {string[]} array of 3 strings
 */
function parseLoadAvg(val) {
  if (!val) return ['—', '—', '—'];
  const parts = val.trim().split(/\s+/);
  return [
    parts[0] || '—',
    parts[1] || '—',
    parts[2] || '—',
  ];
}

/* ============================================================
   6. SET PROGRESS BAR
   Updates a progress bar's width and aria attribute.
   Applies warning colour at WARN_THRESHOLD.
   ============================================================ */
function setProgressBar(barId, trackId, percent) {
  const bar   = document.getElementById(barId);
  const track = document.getElementById(trackId);

  if (!bar || !track) return;

  const clamped = Math.min(100, Math.max(0, percent));

  bar.style.width = `${clamped}%`;
  track.setAttribute('aria-valuenow', clamped);

  // Turn bar red at warning threshold
  if (clamped >= WARN_THRESHOLD) {
    bar.classList.add('progress-bar--warning');
  } else {
    bar.classList.remove('progress-bar--warning');
  }
}

/* ============================================================
   7. SAFE SET TEXT
   Safely updates a DOM element's text content.
   ============================================================ */
function setText(id, value, fallback = '—') {
  const el = document.getElementById(id);
  if (el) el.textContent = (value !== undefined && value !== null && value !== '') ? value : fallback;
}

/* ============================================================
   8. RENDER DASHBOARD
   Maps all fields from status.json to the DOM.
   ============================================================ */
function renderDashboard(data) {
  /* --- System Identity --- */
  setText('hostname',   data.hostname);
  setText('user',       data.user);
  setText('uptime',     data.uptime);
  setText('os',         data.os);
  setText('kernel',     data.kernel);

  /* --- Network --- */
  setText('public-ip',  data.public_ip  || data.public_ip);
  setText('private-ip', data.private_ip || data.private_ip);

  /* --- CPU --- */
  const cpuPct = parseCPUPercent(data.cpu_percent);
  setText('cpu-value', `${cpuPct}%`);
  setText('cpu-hint',  `${cpuPct}% utilization`);
  setProgressBar('cpu-bar', 'cpu-progress-track', cpuPct);

  /* --- Memory --- */
  const memPct = parseMemoryPercent(data);
  setText('memory-value',  `${memPct}%`);
  setText('memory-detail', data.memory ? `${data.memory} used` : `${memPct}% used`);
  setProgressBar('memory-bar', 'mem-progress-track', memPct);

  /* --- Disk --- */
  const diskPct = parseDiskPercent(data.disk);
  setText('disk-value',  `${diskPct}%`);
  const diskDetail = (data.disk_used && data.disk_total)
    ? `${data.disk_used} of ${data.disk_total} used`
    : `${diskPct}% used`;
  setText('disk-detail', diskDetail);
  setProgressBar('disk-bar', 'disk-progress-track', diskPct);

  /* --- Load Average --- */
  const [l1, l5, l15] = parseLoadAvg(data.load_avg);
  setText('load-1m',  l1);
  setText('load-5m',  l5);
  setText('load-15m', l15);

  /* --- Last Updated --- */
  const now = new Date().toLocaleTimeString('en-GB', {
    hour: '2-digit', minute: '2-digit', second: '2-digit'
  });
  setText('last-updated', now);
}

/* ============================================================
   9. FETCH STATUS
   Fetches status.json, handles errors, updates online state.
   Called once on page load then every REFRESH_MS milliseconds.
   ============================================================ */
async function fetchStatus() {
  try {
    const response = await fetch(`${STATUS_URL}?_=${Date.now()}`, {
      // cache-busting query param ensures fresh data on every fetch
      cache: 'no-store',
    });

    if (!response.ok) {
      throw new Error(`HTTP ${response.status} — ${response.statusText}`);
    }

    const data = await response.json();

    // First successful fetch after offline: show recovery toast
    if (!isOnline) {
      showToast('Connection restored — data refreshed', 'success');
    }

    setOnlineStatus(true);
    renderDashboard(data);

  } catch (err) {
    console.error('[CloudOps Monitor] Fetch failed:', err.message);

    // Only show error toast on first failure (not every retry)
    if (isOnline) {
      showToast(`Data fetch failed: ${err.message}`, 'error');
      startRetryCountdown();
    }

    setOnlineStatus(false);
  }
}

/* ============================================================
   10. INIT
   Entry point — called when DOM is ready.
   ============================================================ */
function init() {
  // Start live clock
  startClock();

  // Initial data fetch on page load
  fetchStatus();

  // Auto-refresh every 30 seconds
  setInterval(fetchStatus, REFRESH_MS);

  // Log refresh info to console for DevOps debugging
  console.info(
    `[CloudOps Monitor] Dashboard initialised. Auto-refreshing every ${REFRESH_MS / 1000}s.`
  );
}

/* ============================================================
   START — wait for DOM to be fully parsed
   ============================================================ */
document.addEventListener('DOMContentLoaded', init);

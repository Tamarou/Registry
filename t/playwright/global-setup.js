// ABOUTME: Playwright global setup -- provisions ONE shared DB and ONE morbo server for the run.
// ABOUTME: Owns the full ordering (DB -> server -> health) because Playwright starts webServer
//          before globalSetup, so we do not use webServer; we start the server here ourselves.
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const http = require('http');

const DIR = __dirname; // t/playwright
const URL_FILE = path.join(DIR, '.shared-db-url');
const PID_FILE = path.join(DIR, '.shared-db-pid');
const PORT = 3001;

function waitForHealth(timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    const tick = () => {
      const req = http.get(`http://127.0.0.1:${PORT}/health`, (res) => {
        res.resume();
        if (res.statusCode === 200) return resolve();
        retry();
      });
      req.on('error', retry);
      req.setTimeout(2000, () => req.destroy());
    };
    const retry = () => {
      if (Date.now() > deadline) return reject(new Error('server /health timeout'));
      setTimeout(tick, 500);
    };
    tick();
  });
}

module.exports = async () => {
  // 1) Start the shared DB and capture its URL from the JSON ready-line.
  const db = spawn('carton', ['exec', 'perl', 't/playwright/shared_db.pl'], {
    cwd: process.cwd(),
    stdio: ['pipe', 'pipe', 'inherit'],
  });
  const info = await new Promise((resolve, reject) => {
    let buf = '';
    const timer = setTimeout(() => reject(new Error('shared_db.pl timeout')), 120000);
    db.stdout.on('data', (d) => {
      buf += d.toString();
      const nl = buf.indexOf('\n');
      if (nl >= 0) {
        clearTimeout(timer);
        try { resolve(JSON.parse(buf.slice(0, nl))); } catch (e) { reject(e); }
      }
    });
    db.on('error', reject);
  });
  fs.writeFileSync(URL_FILE, info.url);

  // 2) Start the server against that DB. Use `daemon` (single process, no file
  // watching) rather than morbo so writes during the run (traces, videos, the
  // .shared-db-* dotfiles) cannot trigger a mid-test app restart.
  const server = spawn('carton', ['exec', './registry', 'daemon', '-l', `http://127.0.0.1:${PORT}`], {
    cwd: process.cwd(),
    env: {
      ...process.env,
      DB_URL: info.url,
      EMAIL_SENDER_TRANSPORT: 'Test',
      // One client IP + one long-lived instance would trip the per-IP auth limit
      // across tests; disable it for the E2E server.
      REGISTRY_RATE_LIMIT_DISABLED: '1',
    },
    stdio: ['ignore', 'inherit', 'inherit'],
  });

  // 3) Wait until it serves /health.
  await waitForHealth(120000);

  // carton exec's into the target, so db.pid is the perl process and server.pid
  // is morbo -- SIGTERM to each (in teardown) is sufficient.
  fs.writeFileSync(PID_FILE, JSON.stringify({ db: db.pid, server: server.pid }));
  db.unref();
  server.unref();
  console.log(`[playwright] shared DB + server ready on :${PORT}`);
};

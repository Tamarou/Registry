// ABOUTME: Playwright global setup -- provisions ONE shared DB and ONE morbo server for the run.
// ABOUTME: Owns the full ordering (DB -> server -> health) because Playwright starts webServer
//          before globalSetup, so we do not use webServer; we start the server here ourselves.
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const http = require('http');
const net = require('net');

const DIR = __dirname; // t/playwright
const URL_FILE = path.join(DIR, '.shared-db-url');
const PID_FILE = path.join(DIR, '.shared-db-pid');
const PORT = 3001;

// A leftover daemon from an earlier run answers /health exactly like ours would,
// so waitForHealth cannot tell the two apart: setup prints "ready", our own server
// dies with EADDRINUSE, and every spec then drives a server on a FOREIGN database --
// pages succeed while the row queries that check them come back empty. This setup is
// the sole owner of the port, so refuse to start when anything already holds it.
function assertPortFree() {
  return new Promise((resolve, reject) => {
    const probe = net.createServer();
    probe.once('error', (e) =>
      reject(e.code === 'EADDRINUSE'
        ? new Error(`port ${PORT} is already in use -- kill the leftover server before running`)
        : e));
    probe.once('listening', () => probe.close(resolve));
    probe.listen(PORT, '127.0.0.1');
  });
}

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
  await assertPortFree();

  // 1) Start the shared DB and capture its URL from the JSON ready-line.
  const db = spawn('carton', ['exec', 'perl', 't/playwright/shared_db.pl'], {
    cwd: process.cwd(),
    stdio: ['pipe', 'pipe', 'inherit'],
    detached: true, // own process group so teardown can group-kill grandchildren
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

  // Helper to SIGTERM a process group (negative pid) and ignore if already gone.
  const killGroup = (pid) => { try { process.kill(-pid, 'SIGTERM'); } catch (e) {} };

  // 2) Start the server against that DB. Use `daemon` (single process, no file
  // watching) rather than morbo so writes during the run (traces, videos, the
  // .shared-db-* dotfiles) cannot trigger a mid-test app restart.
  const server = spawn('carton', ['exec', './registry', 'daemon', '-l', `http://127.0.0.1:${PORT}`], {
    cwd: process.cwd(),
    env: (() => {
      const env = {
        ...process.env,
        DB_URL: info.url,
        EMAIL_SENDER_TRANSPORT: 'Test',
        // One client IP + one long-lived instance would trip the per-IP auth limit
        // across tests; disable it for the E2E server.
        REGISTRY_RATE_LIMIT_DISABLED: '1',
      };
      // Payment steps branch on STRIPE_SECRET_KEY: without it they take the
      // demo path and enroll without a gateway. That is what the general e2e
      // run wants -- it has no keys and must not reach Stripe.
      //
      // payment-smoke.spec.js wants the opposite, and stripping the keys made
      // it unpassable: the server enrolled straight through to the completion
      // page, so the Stripe Payment Element it waits for was never rendered.
      //
      // Test-mode keys are therefore passed through, and anything else is
      // stripped. A live key must never reach a browser the suite drives, and
      // the pair must agree -- half a pair mounts Stripe.js against nothing.
      const test_mode =
        /^sk_test_/.test(env.STRIPE_SECRET_KEY || '') &&
        /^pk_test_/.test(env.STRIPE_PUBLISHABLE_KEY || '');

      if (!test_mode) {
        delete env.STRIPE_SECRET_KEY;
        delete env.STRIPE_PUBLISHABLE_KEY;
      }
      return env;
    })(),
    stdio: ['ignore', 'inherit', 'inherit'],
    detached: true, // own process group so teardown can group-kill grandchildren
  });

  // 3) Wait until it serves /health. If the server fails to boot, globalTeardown
  // will NOT run (Playwright only tears down after a successful setup), so we must
  // clean up both children here before rethrowing -- otherwise we leak Postgres.
  try {
    await new Promise((resolve, reject) => {
      server.on('error', reject); // spawn failure (e.g. binary missing) -> fail fast
      // A server that exits during boot must fail now rather than burn the full
      // health timeout waiting for a process that is already gone.
      server.on('exit', (code, signal) =>
        reject(new Error(`server exited during startup (code ${code}, signal ${signal})`)));
      waitForHealth(120000).then(resolve, reject);
    });
  } catch (e) {
    killGroup(server.pid);
    killGroup(db.pid);
    throw e;
  }

  // db.pid / server.pid are the process-group leaders (detached spawns); teardown
  // group-kills them so the underlying perl/daemon (grandchildren of carton exec)
  // are reached regardless of whether carton execs or forks.
  fs.writeFileSync(PID_FILE, JSON.stringify({ db: db.pid, server: server.pid }));
  db.unref();
  server.unref();
  console.log(`[playwright] shared DB + server ready on :${PORT}`);
};

// ABOUTME: Playwright global setup -- starts one shared DB for the whole run.
// ABOUTME: Writes the DB URL and helper PID to dotfiles consumed by the server + teardown.
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const DIR = __dirname;
const URL_FILE = path.join(DIR, '.shared-db-url');
const PID_FILE = path.join(DIR, '.shared-db-pid');

module.exports = async () => {
  const proc = spawn('carton', ['exec', 'perl', 't/playwright/shared_db.pl'], {
    cwd: process.cwd(),
    stdio: ['pipe', 'pipe', 'inherit'],
  });

  const info = await new Promise((resolve, reject) => {
    let buf = '';
    const timer = setTimeout(() => reject(new Error('shared_db.pl timeout')), 120000);
    proc.stdout.on('data', (d) => {
      buf += d.toString();
      const nl = buf.indexOf('\n');
      if (nl >= 0) {
        clearTimeout(timer);
        try { resolve(JSON.parse(buf.slice(0, nl))); }
        catch (e) { reject(e); }
      }
    });
    proc.on('error', reject);
  });

  fs.writeFileSync(URL_FILE, info.url);
  fs.writeFileSync(PID_FILE, JSON.stringify({ perl: info.pid, carton: proc.pid }));
  proc.unref();
  console.log(`[playwright] shared DB ready (perl ${info.pid}, carton ${proc.pid})`);
};

// ABOUTME: Playwright global teardown -- stops the shared server + DB and removes dotfiles.
const fs = require('fs');
const path = require('path');

const DIR = __dirname;
const URL_FILE = path.join(DIR, '.shared-db-url');
const PID_FILE = path.join(DIR, '.shared-db-pid');

module.exports = async () => {
  try {
    const { db, server } = JSON.parse(fs.readFileSync(PID_FILE, 'utf8'));
    // Group-kill (negative pid) so the underlying daemon/perl -- grandchildren of
    // the detached `carton exec` group leaders -- are reached. The DB's SIGTERM
    // handler then runs a clean Test::PostgreSQL teardown. Stop the server first.
    try { process.kill(-server, 'SIGTERM'); } catch (e) {}
    try { process.kill(-db, 'SIGTERM'); } catch (e) {}
  } catch (e) { /* already gone */ }
  for (const f of [URL_FILE, PID_FILE]) { try { fs.unlinkSync(f); } catch (e) {} }
};

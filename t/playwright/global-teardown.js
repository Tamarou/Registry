// ABOUTME: Playwright global teardown -- stops the shared DB and removes dotfiles.
const fs = require('fs');
const path = require('path');

const DIR = __dirname;
const URL_FILE = path.join(DIR, '.shared-db-url');
const PID_FILE = path.join(DIR, '.shared-db-pid');

module.exports = async () => {
  try {
    const { perl, carton } = JSON.parse(fs.readFileSync(PID_FILE, 'utf8'));
    try { process.kill(perl, 'SIGTERM'); } catch (e) {}
    try { process.kill(carton, 'SIGTERM'); } catch (e) {}
  } catch (e) {}
  for (const f of [URL_FILE, PID_FILE]) { try { fs.unlinkSync(f); } catch (e) {} }
};

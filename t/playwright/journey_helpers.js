// ABOUTME: Shared helpers for the per-persona user-journey specs.
// ABOUTME: One copy, because four copies of a login helper drift and only one of them is right.
const { execFileSync } = require('child_process');

// Run a command through the Perl side-channel, for the two things that need
// application code rather than SQL: minting a login token, and writing through
// a DAO. Reads use psql instead -- see queryJson.
function helper(testDB, args) {
  return execFileSync(
    'carton',
    ['exec', 'perl', 't/playwright/lifecycle_helpers.pl', ...args],
    { cwd: process.cwd(), env: { ...process.env, DB_URL: testDB.dbUrl }, encoding: 'utf8' }
  ).trim();
}

function loginToken(testDB, schema, userId) {
  return helper(testDB, ['login-token', schema, userId]);
}

// Reads go through psql, not the Perl side-channel. The Perl script's first act
// is to load Registry::DAO, which costs 6-9s of module compilation per call, and
// these specs make 61 reads between them -- about half of morgan.spec.js's
// runtime and lifecycle.spec.js's (#428). psql costs ~0.2s a call, and
// payment-smoke.spec.js already reads the database this way.
//
// The contract is unchanged: `?` placeholders, a schema to resolve against, a
// parsed array back.
//
// Two things about psql make this safe rather than string-slinging. It does NOT
// interpolate variables given to -c -- that string goes straight to the server
// -- so the query arrives on stdin, where the lexer does process them. And
// :'v' interpolates a value as a quoted literal while :"v" interpolates an
// identifier, each escaping what it contains, so a tenant named O'Brien Arts
// cannot change the shape of the query.
function queryJson(testDB, schema, sql, ...bind) {
  const binds = bind.map(String);

  // A `?` here is always a placeholder: no caller uses jsonb's ? / ?| / ?&
  // operators, and none has a literal ? inside a string. Counting rather than
  // trusting that, because a mismatch would otherwise interpolate the wrong
  // value into the wrong column and still return rows.
  const holes = (sql.match(/\?/g) || []).length;
  if (holes !== binds.length) {
    throw new Error(
      `queryJson: ${holes} placeholder(s) but ${binds.length} bind(s) in: ${sql}`
    );
  }

  let n = 0;
  const interpolated = sql.replace(/\?/g, () => `:'v${++n}'`);

  const args = [testDB.dbUrl, '-At', '-q', '-v', 'ON_ERROR_STOP=1', '-v', `s=${schema}`];
  binds.forEach((b, i) => args.push('-v', `v${i + 1}=${b}`));
  args.push('-f', '-');

  // search_path matches what Registry::DAO sets, so a tenant query resolves
  // against the same schema it always did.
  const script =
    'SET search_path TO :"s", public;\n'
    + `SELECT COALESCE(json_agg(t), '[]'::json)::text FROM (${interpolated}) t;\n`;

  const out = execFileSync('psql', args, {
    input: script,
    env: { ...process.env, PGCLIENTENCODING: 'UTF8' },
    encoding: 'utf8',
  }).trim();

  return JSON.parse(out);
}

function execSql(testDB, schema, sql, ...bind) {
  return helper(testDB, ['exec-sql', schema, sql, ...bind.map(String)]);
}

// Magic-link sign-in. The confirm button is a real click rather than a direct
// POST, because a journey that cannot press the button has not signed in.
async function loginWithToken(page, token, baseUrl = '') {
  await page.goto(`${baseUrl}/auth/magic/${token}`);
  await page.waitForSelector('button[type="submit"]');
  await page.click('button[type="submit"]');
  await page.waitForLoadState('networkidle');
}

// Dates are derived, never written down. A fixture pinned to a literal date
// stops testing what it says the day it expires -- see #368.
function daysFromNow(n) {
  const d = new Date();
  d.setDate(d.getDate() + n);
  return d.toISOString().split('T')[0];
}

module.exports = { helper, loginToken, queryJson, execSql, loginWithToken, daysFromNow };

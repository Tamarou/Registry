// ABOUTME: Shared helpers for the per-persona user-journey specs.
// ABOUTME: One copy, because four copies of a login helper drift and only one of them is right.
const { execFileSync } = require('child_process');

// Run a command through the Perl side-channel. The journeys need to read and
// seed tenant-schema state that has no HTTP surface -- a login token, the row a
// screen is supposed to have written -- without asserting through the thing
// under test.
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

function queryJson(testDB, schema, sql, ...bind) {
  return JSON.parse(helper(testDB, ['query-json', schema, sql, ...bind.map(String)]));
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

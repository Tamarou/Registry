// ABOUTME: Serial lifecycle E2E — Morgan signs up, builds a free program; Nancy
// ABOUTME: enrolls her child; Amara takes attendance — all in Morgan's tenant schema.
const { test, expect } = require('./fixtures/base');
const { execFileSync } = require('child_process');

function helper(testDB, args) {
  return execFileSync(
    'carton',
    ['exec', 'perl', 't/playwright/lifecycle_helpers.pl', ...args],
    { cwd: process.cwd(), env: { ...process.env, DB_URL: testDB.dbUrl }, encoding: 'utf8' }
  ).trim();
}
function loginToken(testDB, schema, userId) { return helper(testDB, ['login-token', schema, userId]); }
function queryJson(testDB, schema, sql, ...bind) { return JSON.parse(helper(testDB, ['query-json', schema, sql, ...bind.map(String)])); }

async function loginWithToken(page, token, baseUrl = '') {
  await page.goto(`${baseUrl}/auth/magic/${token}`);
  await page.waitForSelector('button[type="submit"]');
  await page.click('button[type="submit"]');
  await page.waitForLoadState('networkidle');
}

test.describe.configure({ mode: 'serial', timeout: 180000 });

const RUN = String(Date.now());
const state = {
  orgName: `Lifecycle Arts ${RUN}`,
  morganUsername: `morgan_${RUN}`, morganEmail: `morgan_${RUN}@test.com`,
  amaraUsername: `amara_${RUN}`,   amaraEmail: `amara_${RUN}@test.com`,
  nancyUsername: `nancy_${RUN}`,   nancyEmail: `nancy_${RUN}@test.com`,
  childName: `Kid ${RUN}`,
};

test.describe('Lifecycle: Morgan -> Nancy -> Amara', () => {
  // legs added in later tasks
});

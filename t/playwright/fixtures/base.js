// ABOUTME: Base Playwright fixtures for Registry testing
// ABOUTME: Provides database setup, test data creation, and common utilities

const playwright = require('@playwright/test');
const base = playwright.test;
const expect = playwright.expect;
const { spawn, exec } = require('child_process');
const { promisify } = require('util');

const execAsync = promisify(exec);

// Database setup helper - detects CI vs local environment
class TestDB {
  constructor() {
    this.testId = `${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
    this.isCI = process.env.CI === 'true' || process.env.GITHUB_ACTIONS === 'true';
  }

  async setup() {
    if (this.isCI) {
      // CI environment: use shared database from environment
      this.dbUrl = process.env.DB_URL || 'postgresql://postgres:postgres@localhost:5432/registry_ci';
      console.log(`Using CI database: ${this.dbUrl}`);

      // Set environment for Registry app
      process.env.DB_URL = this.dbUrl;
    } else {
      // Local environment: create individual test database
      // Start database manager process
      this.dbManagerProcess = spawn('carton', ['exec', 'perl', 't/playwright/db_manager.pl', 'create'], {
        cwd: '/home/perigrin/dev/Registry',
        stdio: ['pipe', 'pipe', 'pipe']
      });

      // Wait for database creation and get the info
      const dbInfo = await new Promise((resolve, reject) => {
        let output = '';
        const timeout = setTimeout(() => {
          reject(new Error('Database creation timeout'));
        }, 60000);

        this.dbManagerProcess.stdout.on('data', (data) => {
          output += data.toString();
          try {
            const info = JSON.parse(output);
            if (info.url && info.status === 'ready') {
              clearTimeout(timeout);
              resolve(info);
            }
          } catch (e) {
            // Not complete JSON yet, keep reading
          }
        });

        this.dbManagerProcess.stderr.on('data', (data) => {
          console.error('Database manager error:', data.toString());
        });

        this.dbManagerProcess.on('error', (error) => {
          clearTimeout(timeout);
          reject(error);
        });
      });

      this.dbUrl = dbInfo.url;
      console.log(`Created test database: ${this.dbUrl}`);

      // Set environment for Registry app
      process.env.DB_URL = this.dbUrl;

      // Keep the database manager process active by sending it a newline
      // This ensures it enters the STDIN reading loop and stays alive
      this.dbManagerProcess.stdin.write('\n');
    }
  }

  async teardown() {
    if (this.isCI) {
      // CI environment: no cleanup needed for shared database
      console.log('CI environment: no database cleanup needed');
    } else {
      // Local environment: shutdown the database manager process
      if (this.dbManagerProcess && !this.dbManagerProcess.killed) {
        this.dbManagerProcess.stdin.write('SHUTDOWN\n');
        this.dbManagerProcess.stdin.end();

        // Give it a moment to shutdown gracefully
        setTimeout(() => {
          if (!this.dbManagerProcess.killed) {
            this.dbManagerProcess.kill('SIGTERM');
          }
        }, 1000);
      }
    }
  }
}

// Fixtures following Registry test patterns
const test = base.extend({
  // Database fixture - automatic setup/teardown
  testDB: async ({}, use) => {
    const db = new TestDB();
    await db.setup();
    await use(db);
    await db.teardown();
  },

  // Page with Registry-specific helpers
  registryPage: async ({ page, testDB }, use) => {
    const isCI = process.env.CI === 'true' || process.env.GITHUB_ACTIONS === 'true';
    let serverUrl;
    let serverProcess;

    if (isCI) {
      // CI environment: use shared server from baseURL in playwright.config.js
      serverUrl = 'http://localhost:3000';  // This should match the CI workflow
      console.log(`Using CI server: ${serverUrl}`);

      // Wait for server to be ready (it should already be running)
      await new Promise((resolve, reject) => {
        const timeout = setTimeout(() => {
          reject(new Error('CI server not responding'));
        }, 10000);

        const checkServer = async () => {
          try {
            const response = await fetch(`${serverUrl}/health`);
            if (response.ok) {
              clearTimeout(timeout);
              resolve();
            } else {
              setTimeout(checkServer, 500);
            }
          } catch (e) {
            setTimeout(checkServer, 500);
          }
        };

        setTimeout(checkServer, 1000);
      });
    } else {
      // Local environment: start individual server per test
      // Use a unique port for each test to avoid conflicts
      const port = 3000 + Math.floor(Math.random() * 1000);
      serverUrl = `http://localhost:${port}`;

      // Start Registry server with the test database
      console.log(`Starting server with database URL: ${testDB.dbUrl} on port ${port}`);
      serverProcess = spawn('carton', ['exec', 'morbo', './registry', '-l', serverUrl], {
        env: { ...process.env, DB_URL: testDB.dbUrl },
        cwd: '/home/perigrin/dev/Registry',
        stdio: 'pipe'
      });

      // Log server output for debugging
      serverProcess.stdout.on('data', (data) => {
        console.log('Server stdout:', data.toString());
      });

      serverProcess.stderr.on('data', (data) => {
        console.error('Server stderr:', data.toString());
      });

      // Wait for server to start
      await new Promise((resolve, reject) => {
        const timeout = setTimeout(() => {
          reject(new Error('Server startup timeout'));
        }, 30000);

        const checkServer = async () => {
          try {
            const response = await fetch(`${serverUrl}/health`);
            if (response.ok) {
              clearTimeout(timeout);
              resolve();
            } else {
              setTimeout(checkServer, 500);
            }
          } catch (e) {
            setTimeout(checkServer, 500);
          }
        };

        setTimeout(checkServer, 2000); // Give server time to start
      });
    }

    // Store server URL for page navigation
    page.serverUrl = serverUrl;

    // Helper methods that mirror Test::Registry::Helpers
    page.workflowUrl = (workflowSlug) => `/workflow/${workflowSlug}`;
    page.workflowRunStepUrl = (workflowSlug, runId, stepSlug) => `/workflow/${workflowSlug}/run/${runId}/step/${stepSlug}`;

    // Override page.goto to use the dynamic server URL
    const originalGoto = page.goto.bind(page);
    page.goto = async (url, options) => {
      if (url.startsWith('/')) {
        url = serverUrl + url;
      }
      return originalGoto(url, options);
    };

    // UTF-8 validation helper
    page.expectUTF8Rendering = async () => {
      // Check that emojis and special characters render correctly
      const emojiElements = await page.locator('text=/[\\u{1F600}-\\u{1F64F}]|[\\u{1F300}-\\u{1F5FF}]|[\\u{1F680}-\\u{1F6FF}]|[\\u{1F1E0}-\\u{1F1FF}]/u').all();
      for (const emoji of emojiElements) {
        await expect(emoji).toBeVisible();
      }
    };

    // Layout validation helper
    page.expectWorkflowLayout = async () => {
      // Verify essential layout elements
      await expect(page.locator('html')).toHaveAttribute('lang');
      await expect(page.locator('head meta[charset]')).toBeAttached();
      await expect(page.locator('head title')).toBeAttached();

      // Check for CSS inclusion
      const cssLinks = await page.locator('link[rel="stylesheet"]').count();
      expect(cssLinks).toBeGreaterThan(0);

      // Check for HTMX inclusion
      await expect(page.locator('script[src*="htmx"]')).toBeAttached();
    };

    // HTMX interaction helper
    page.expectHTMXResponse = async (triggerSelector, expectedSelector) => {
      await page.locator(triggerSelector).click();
      await expect(page.locator(expectedSelector)).toBeVisible({ timeout: 5000 });
    };

    await use(page);

    // Clean up server (only for local environment)
    if (!isCI && serverProcess && !serverProcess.killed) {
      serverProcess.kill('SIGTERM');
    }
  },
});

module.exports = { test, expect };
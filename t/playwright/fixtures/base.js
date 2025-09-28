// ABOUTME: Base Playwright fixtures for Registry testing
// ABOUTME: Provides database setup, test data creation, and common utilities

const playwright = require('@playwright/test');
const base = playwright.test;
const expect = playwright.expect;
const { spawn, exec } = require('child_process');
const { promisify } = require('util');

const execAsync = promisify(exec);

// Database setup helper - uses Perl Test::Registry::DB via carton
class TestDB {
  constructor() {
    this.testId = `${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
  }

  async setup() {
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

  async teardown() {
    // Shutdown the database manager process to trigger Test::PostgreSQL cleanup
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
    // Use a unique port for each test to avoid conflicts
    const port = 3000 + Math.floor(Math.random() * 1000);
    const serverUrl = `http://localhost:${port}`;

    // Start Registry server with the test database
    console.log(`Starting server with database URL: ${testDB.dbUrl} on port ${port}`);
    const serverProcess = spawn('carton', ['exec', 'morbo', './registry', '-l', serverUrl], {
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

    // Clean up server
    if (serverProcess && !serverProcess.killed) {
      serverProcess.kill('SIGTERM');
    }
  },
});

module.exports = { test, expect };
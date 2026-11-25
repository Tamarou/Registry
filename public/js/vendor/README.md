# Vendored scripts

Third-party scripts served from our own origin, so the CSP `script-src` needs no
public CDN. Each file is copied unchanged from the npm registry tarball
(`npm pack <package>@<version>`). t/security/self-hosted-scripts.t checks each
file's version against this table; keep them in step when upgrading.

| File | npm package | Version | Path in tarball | License |
|------|-------------|---------|-----------------|---------|
| htmx.min.js | htmx.org | 2.0.3 | package/dist/htmx.min.js | 0BSD |
| chart.umd.min.js | chart.js | 4.6.2 | package/dist/chart.umd.min.js | MIT |

htmx 2.0.3 is the version the layouts loaded from unpkg before self-hosting.

chart.js 4.6.2 is what `https://cdn.jsdelivr.net/npm/chart.js` served on
2026-11-25: that unversioned URL resolves to the npm `latest` dist-tag (4.6.2)
and the package's `jsdelivr` entry, `dist/chart.umd.min.js`.

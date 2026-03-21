#!/usr/bin/env node

// Playwright harness for running Defold HTML5 benchmark bundles.
// Serves the bundle directory, launches headless Chromium, polls for results,
// and writes the benchmark JSON to stdout.
//
// Usage: node defold_html5_harness.mjs <bundle-dir>

import { chromium } from "playwright";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { join, extname, resolve } from "node:path";

const MIME_TYPES = {
  ".html": "text/html",
  ".js": "application/javascript",
  ".mjs": "application/javascript",
  ".wasm": "application/wasm",
  ".json": "application/json",
  ".css": "text/css",
  ".png": "image/png",
  ".ico": "image/x-icon",
};

const POLL_INTERVAL_MS = 500;
const TIMEOUT_MS = 120_000;

const bundleDir = process.argv[2];
if (!bundleDir) {
  process.stderr.write("Usage: node defold_html5_harness.mjs <bundle-dir>\n");
  process.exit(1);
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  const requestedPath = url.pathname === "/" ? "/index.html" : url.pathname;
  const filePath = resolve(join(bundleDir, requestedPath));
  const resolved = resolve(bundleDir);

  // Prevent path traversal outside bundle directory
  if (!filePath.startsWith(resolved + "/") && filePath !== resolved) {
    res.writeHead(403);
    res.end("Forbidden");
    return;
  }

  const ext = extname(filePath);
  const contentType = MIME_TYPES[ext] || "application/octet-stream";

  res.setHeader("Cross-Origin-Opener-Policy", "same-origin");
  res.setHeader("Cross-Origin-Embedder-Policy", "require-corp");

  try {
    const data = await readFile(filePath);
    res.writeHead(200, { "Content-Type": contentType });
    res.end(data);
  } catch {
    res.writeHead(404);
    res.end("Not found");
  }
});

let browser;

try {
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;
  const url = `http://127.0.0.1:${port}`;

  browser = await chromium.launch({
    headless: true,
    args: [
      "--use-gl=angle",
      "--use-angle=swiftshader",
      "--enable-unsafe-swiftshader",
    ],
  });

  const page = await browser.newPage();
  await page.goto(url);

  const start = Date.now();
  let title = "";

  while (Date.now() - start < TIMEOUT_MS) {
    title = await page.title();
    if (title.startsWith("DONE") || title.startsWith("FAIL")) {
      break;
    }
    await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
  }

  if (title.startsWith("DONE")) {
    const result = await page.evaluate(() => window.__luabench_result);
    if (result) {
      process.stdout.write(result);
    } else {
      process.stderr.write("Error: document.title is DONE but window.__luabench_result is empty\n");
      process.exit(1);
    }
  } else if (title.startsWith("FAIL")) {
    process.stderr.write(`Benchmark failed: ${title}\n`);
    process.exit(1);
  } else {
    process.stderr.write(`Timeout after ${TIMEOUT_MS / 1000}s (last title: ${JSON.stringify(title)})\n`);
    process.exit(1);
  }
} catch (err) {
  process.stderr.write(`Harness error: ${err.message}\n`);
  process.exit(1);
} finally {
  if (browser) await browser.close();
  server.closeAllConnections();
  await new Promise((res) => server.close(res));
}

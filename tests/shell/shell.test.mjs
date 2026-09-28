import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chromium, firefox, webkit } from 'playwright';
import { createServer } from 'node:http';
import { readFile, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync, spawn } from 'node:child_process';
import { createServer as createNetServer } from 'node:net';
import { mkdir } from 'node:fs/promises';
import { gzipSync } from 'node:zlib';
import { randomBytes } from 'node:crypto';

const root = fileURLToPath(new URL('../../', import.meta.url));
const tool = process.env.SHELL_TOOL || join(root, 'zig-out', 'bin', process.platform === 'win32' ? 'labelle-web-shell.exe' : 'labelle-web-shell');
/** Encode the unsigned section length for the valid wasm test payload. */
function leb(n) {
  const bytes = [];
  do { const b = n & 127; n >>>= 7; bytes.push(b | (n ? 128 : 0)); } while (n);
  return bytes;
}
// Valid wasm with an inert custom section: enough bytes to see intermediate
// download progress. Random payload keeps gzip from collapsing the transfer.
const payload = Buffer.concat([Buffer.from([0]), randomBytes(256 * 1024), Buffer.alloc(256 * 1024)]);
const wasm = Buffer.concat([Buffer.from([0,97,115,109,1,0,0,0,0,...leb(payload.length)]), payload]);
const gzip = gzipSync(wasm);
const fixtureJS = `Module.instantiateWasm({}, function(instance, compiled) {
  window.receivedWasm = instance instanceof WebAssembly.Instance && compiled instanceof WebAssembly.Module;
  setTimeout(function() { Module.onRuntimeInitialized(); window.gameReady = true; }, 100);
});`;
const browsers = { chromium, firefox, webkit };
const providerExe = process.env.PROVIDER_EXE || join(root, 'zig-out', 'bin', process.platform === 'win32' ? 'labelle-web.exe' : 'labelle-web');
// A page with no <head>, an early inline script, inert <noscript>/<template>
// scripts and an executable script in an SVG <template>: every executable
// one must already see the run.env block the serve hook injects.
const runEnvPage = `<!doctype html>
<html><noscript><script>window.inert = 'noscript';</script></noscript>
<template><script>window.inert = 'template';</script></template>
<svg><template><script>window.svgEarly = window.LABELLE_RUN_ENV && window.LABELLE_RUN_ENV.LABELLE_SCENE;</script></template></svg>
<script>window.early = window.LABELLE_RUN_ENV && window.LABELLE_RUN_ENV.LABELLE_SCENE;</script>
<body><p>page</p></body></html>`;

/** A free local TCP port. */
function freePort() {
  return new Promise((resolve, reject) => {
    const probe = createNetServer();
    probe.once('error', reject);
    probe.listen(0, '127.0.0.1', () => { const { port } = probe.address(); probe.close(() => resolve(port)); });
  });
}

/** Run the provider's `serve` hook on `web` with `run.env`, as `labelle run --scene=intro` does. */
async function serveWithRunEnv(dir, html) {
  const target = join(dir, 'project', '.labelle', 'b_wasm');
  const web = join(target, 'zig-out', 'web');
  await mkdir(web, { recursive: true });
  await writeFile(join(web, 'index.html'), html);
  await writeFile(join(web, 'game.js'), '');
  await writeFile(join(web, 'game.wasm'), wasm);
  const port = await freePort();
  const zig = /\.zig_exe = "([^"]+)"/.exec(execFileSync('zig', ['env'], { encoding: 'utf8' }))[1];
  await writeFile(join(dir, 'serve.json'), JSON.stringify({ schema_version: 1, port, open_browser: false }));
  const context = {
    contract_version: '1.3.0', invocation: { kind: 'hook', id: 'serve', step: 'run', phase: 'replace' },
    package_dir: root.replace(/[\\/]$/, ''), project_dir: join(dir, 'project'), target: 'wasm', lock_file: join(dir, 'project', 'labelle.lock'),
    config_file: join(dir, 'serve.json'), output_dir: join(target, 'zig-out'), zig_executable: zig, optimize: 'Debug', progress: 'json',
    target_dir: target, cache_dir: join(dir, 'cache'), env_file: null,
    run: { env: [{ name: 'LABELLE_SCENE', value: 'intro' }], args: [], timeout_ms: 60000, watch: null },
  };
  await writeFile(join(dir, 'context.json'), JSON.stringify(context));
  const proc = spawn(providerExe, [], { env: { ...process.env, LABELLE_CONTEXT: join(dir, 'context.json') }, stdio: ['ignore', 'ignore', 'pipe'] });
  let stderr = '';
  proc.stderr.on('data', d => { stderr += d; });
  const url = `http://127.0.0.1:${port}/`;
  for (let i = 0; ; i++) {
    try { if ((await fetch(url)).ok) break; } catch {}
    if (proc.exitCode !== null || i > 200) { proc.kill(); throw new Error('serve hook did not start: ' + stderr); }
    await new Promise(r => setTimeout(r, 50));
  }
  return { url, stop: () => new Promise(r => { if (proc.exitCode !== null) return r(); proc.once('exit', r); proc.kill(); }) };
}

for (const name of (process.env.BROWSERS || 'chromium,firefox,webkit').split(',')) {
  test(name + ': shell browser acceptance', { timeout: 120000 }, async t => {
    const dir = await mkdtemp(join(tmpdir(), 'labelle-shell-'));
    let browser;
    let server;
    try {
      await writeFile(join(dir, 'game.wasm'), wasm);
      execFileSync(tool, [dir]);
      const html = await readFile(join(dir, 'index.html'));
      const js = await readFile(join(dir, 'labelle-loader.js'));
      const logo = await readFile(join(dir, 'labelle-logo.png'));
      const realDir = process.env.EMCC_FIXTURE && resolve(process.env.EMCC_FIXTURE);
      if (realDir) execFileSync(tool, [realDir]);
      const heldTransfers = new Set();
      server = createServer(async (req, res) => {
        const parts = new URL(req.url, 'http://localhost').pathname.split('/');
        const mode = parts[1];
        const file = parts.at(-1) || 'index.html';
        if (mode === 'real' && realDir) {
          try {
            const content = await readFile(join(realDir, file));
            res.setHeader('Content-Type', file.endsWith('.wasm') ? 'application/wasm' : file.endsWith('.js') ? 'text/javascript' : file.endsWith('.png') ? 'image/png' : 'text/html');
            res.end(content);
          } catch { res.writeHead(404); res.end(); }
          return;
        }
        if (file === 'index.html') {
          res.setHeader('Content-Type', 'text/html');
          res.end(mode === 'unknown' ? html.toString().replace(`data-wasm-bytes="${wasm.length}"`, 'data-wasm-bytes="0"') : html);
        } else if (file === 'labelle-loader.js') {
          if (mode === 'loader-failure') { res.writeHead(404); res.end(); return; }
          res.setHeader('Content-Type', 'text/javascript'); res.end(js);
        } else if (file === 'labelle-logo.png') {
          res.setHeader('Content-Type', 'image/png'); res.end(logo);
        } else if (file === 'game.js') {
          if (mode === 'js-failure') { res.writeHead(404); res.end(); return; }
          res.setHeader('Content-Type', 'text/javascript');
          if (mode === 'js-syntax') res.end('function (');
          else if (mode === 'js-throw') res.end('throw new Error("startup execution failed");');
          else res.end(fixtureJS);
        } else if (file === 'game.wasm' || file === 'relocated.wasm') {
          if (mode === 'http-failure') { res.writeHead(503); res.end('unavailable'); return; }
          if (mode === 'compile-failure') { res.end('not wasm'); return; }
          const data = mode === 'gzip' ? gzip : wasm;
          res.setHeader('Content-Type', 'application/octet-stream'); // host MIME does not disable streaming
          res.setHeader('Content-Length', data.length);
          if (mode === 'gzip') res.setHeader('Content-Encoding', 'gzip');
          let offset = 0;
          const interval = setInterval(() => {
            if (mode === 'stream-failure' && offset > 32768) { clearInterval(interval); res.destroy(); return; }
            // Keep the response incomplete until the test has observed progress.
            // CI scheduling can otherwise finish the transfer between assertions.
            if (offset >= 65536 && heldTransfers.has(mode)) return;
            if (offset >= data.length) { clearInterval(interval); res.end(); return; }
            res.write(data.subarray(offset, offset += 16384));
          }, 20);
          res.on('close', () => clearInterval(interval));
        } else { res.writeHead(404); res.end(); }
      });
      await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
      const base = `http://127.0.0.1:${server.address().port}`;
      browser = await browsers[name].launch({ headless: true });
      /** Open an isolated page with optional startup hooks and error capture. */
      async function pageFor(mode, init) {
        const page = await browser.newPage({ viewport: { width: 800, height: 600 }, deviceScaleFactor: 2 });
        const errors = [];
        page.on('pageerror', e => errors.push(e.message));
        await page.addInitScript(() => {
          window.byteText = [];
          document.addEventListener('DOMContentLoaded', () => {
            const status = document.querySelector('#loading-status');
            new MutationObserver(() => window.byteText.push(status.textContent)).observe(status, { childList: true });
          });
        });
        if (init) await page.addInitScript(init);
        await page.goto(`${base}/${mode}/index.html`);
        return { page, errors };
      }
      for (const mode of ['slow', 'gzip', 'unknown', 'fallback']) {
        await t.test(mode + ': counted download, startup, DPR and resize', async () => {
          heldTransfers.add(mode);
          const { page, errors } = await pageFor(mode, mode === 'fallback' ? () => { WebAssembly.instantiateStreaming = undefined; } : undefined);
          try {
            await page.waitForFunction(() => /^[1-9]/.test(document.querySelector('#loading-status').textContent));
            assert.equal(await page.locator('#loading').isVisible(), true);
            if (mode === 'unknown') assert.equal(await page.locator('progress').getAttribute('value'), null);
            else {
              const value = await page.locator('progress').evaluate(el => el.value);
              assert.ok(value > 0 && value < 1, 'intermediate progress is observable');
            }
            heldTransfers.delete(mode);
            await page.waitForFunction(() => window.gameReady);
            assert.equal(await page.evaluate(() => window.receivedWasm), true);
            const observed = await page.evaluate(() => window.byteText);
            assert.ok(observed.some(text => text.startsWith(wasm.length.toLocaleString('en-US') + ' bytes')), 'counts final decompressed byte total');
            assert.equal(await page.locator('#loading').isVisible(), false);
            await page.waitForFunction(() => canvas.width === 1600 && canvas.height === 1200);
            await page.setViewportSize({ width: 640, height: 480 });
            await page.waitForFunction(() => canvas.width === 1280 && canvas.height === 960);
            assert.deepEqual(errors, []);
          } finally { heldTransfers.delete(mode); await page.close(); }
        });
      }
      for (const mode of ['http-failure', 'compile-failure', 'js-failure', 'stream-failure', 'loader-failure']) {
        await t.test(mode + ': readable error and no hidden loader', async () => {
          const { page, errors } = await pageFor(mode);
          try {
            await page.waitForFunction(() => document.querySelector('#loading').classList.contains('failed'));
            assert.equal(await page.locator('#loading').isVisible(), true);
            assert.equal(await page.locator('#loading').getAttribute('aria-busy'), 'false');
            assert.match(await page.locator('[role=alert]').textContent(), /Could not load/);
            assert.deepEqual(errors, []);
          } finally { await page.close(); }
        });
      }
      for (const mode of ['js-syntax', 'js-throw']) {
        await t.test(mode + ': execution error fails the loading UI', async () => {
          const { page, errors } = await pageFor(mode);
          try {
            await page.waitForFunction(() => document.querySelector('#loading').classList.contains('failed'));
            assert.equal(await page.locator('#loading').isVisible(), true);
            assert.match(await page.locator('[role=alert]').textContent(), /Could not load/);
            assert.equal(errors.length, 1, 'the intentional execution error remains observable');
          } finally { await page.close(); }
        });
      }
      await t.test('successful startup removes its temporary error listener', async () => {
        const { page, errors } = await pageFor('slow');
        try {
          await page.waitForFunction(() => window.gameReady);
          await page.evaluate(() => window.dispatchEvent(new ErrorEvent('error', { message: 'later game error' })));
          assert.equal(await page.locator('#loading').isVisible(), false);
          assert.deepEqual(errors, []);
        } finally { await page.close(); }
      });
      await t.test('custom hooks, locateFile, runtime abort, and backend size reset', async () => {
        const { page, errors } = await pageFor('slow', () => {
          window.Module = {
            locateFile(file, prefix) { window.located = [file, prefix]; return 'relocated.wasm'; },
            onRuntimeInitialized() { window.previousReadyCalled = true; },
            onAbort() { window.previousAbortCalled = true; }
          };
        });
        try {
          await page.waitForFunction(() => window.gameReady);
          assert.equal(await page.evaluate(() => window.previousReadyCalled), true);
          assert.deepEqual(await page.evaluate(() => window.located), ['game.wasm', '']);
          await page.evaluate(() => { canvas.width = 10; canvas.height = 10; });
          await page.waitForFunction(() => canvas.width === 1600 && canvas.height === 1200);
          await page.evaluate(() => Module.onAbort('test abort'));
          assert.equal(await page.evaluate(() => window.previousAbortCalled), true);
          assert.equal(await page.locator('#loading').isVisible(), true);
          assert.deepEqual(errors, []);
        } finally { await page.close(); }
      });
      await t.test('locateFile exceptions become a visible loading error', async () => {
        const { page, errors } = await pageFor('slow', () => {
          window.Module = { locateFile() { throw new Error('broken locator'); } };
        });
        try {
          await page.waitForFunction(() => document.querySelector('#loading').classList.contains('failed'));
          assert.deepEqual(errors, []);
        } finally { await page.close(); }
      });
      await t.test('custom intrinsic canvas does not grow at high DPR', async () => {
        const page = await browser.newPage({ deviceScaleFactor: 2 });
        try {
          await page.setContent('<canvas id="custom"></canvas>');
          await page.addScriptTag({ content: js.toString() });
          const sizes = await page.evaluate(async () => {
            const canvas = document.getElementById('custom');
            const before = [canvas.width, canvas.height, canvas.clientWidth, canvas.clientHeight];
            LabelleLoader.install({}, { canvas });
            for (let i = 0; i < 10; i++) await new Promise(requestAnimationFrame);
            return [before, [canvas.width, canvas.height, canvas.clientWidth, canvas.clientHeight]];
          });
          assert.deepEqual(sizes[0], sizes[1]);
        } finally { await page.close(); }
      });
      await t.test('serve: run.env runs before every early script', async () => {
        const served = await serveWithRunEnv(join(dir, 'run-env'), runEnvPage);
        const page = await browser.newPage();
        try {
          const errors = [];
          page.on('pageerror', e => errors.push(e.message));
          await page.goto(served.url);
          const seen = await page.evaluate(() => ({
            early: window.early, svgEarly: window.svgEarly, inert: window.inert, mode: document.compatMode,
            first: document.head.firstElementChild && document.head.firstElementChild.textContent.includes('LABELLE_RUN_ENV'),
          }));
          assert.deepEqual(seen, { early: 'intro', svgEarly: 'intro', inert: undefined, mode: 'CSS1Compat', first: true });
          assert.deepEqual(errors, []);
        } finally { await page.close(); await served.stop(); }
      });
      if (realDir) await t.test('actual emcc glue reaches main', async () => {
        const { page, errors } = await pageFor('real');
        try {
          await page.waitForFunction(() => document.body.dataset.emccMain === 'yes');
          assert.equal(await page.locator('#loading').isVisible(), false);
          assert.deepEqual(errors, []);
        } finally { await page.close(); }
      });
    } finally {
      await browser?.close();
      if (server) await new Promise(resolve => server.close(resolve));
      await rm(dir, { recursive: true, force: true });
    }
  });
}

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chromium, firefox, webkit } from 'playwright';
import { createServer } from 'node:http';
import { readFile, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { gzipSync } from 'node:zlib';
import { randomBytes } from 'node:crypto';

const root = fileURLToPath(new URL('../../', import.meta.url));
const tool = process.env.SHELL_TOOL || join(root, 'zig-out', 'bin', process.platform === 'win32' ? 'labelle-web-shell.exe' : 'labelle-web-shell');
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
          res.setHeader('Content-Type', 'text/javascript'); res.end(fixtureJS);
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
            if (offset >= data.length) { clearInterval(interval); res.end(); return; }
            res.write(data.subarray(offset, offset += 16384));
          }, 20);
          res.on('close', () => clearInterval(interval));
        } else { res.writeHead(404); res.end(); }
      });
      await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
      const base = `http://127.0.0.1:${server.address().port}`;
      browser = await browsers[name].launch({ headless: true });
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
          const { page, errors } = await pageFor(mode, mode === 'fallback' ? () => { WebAssembly.instantiateStreaming = undefined; } : undefined);
          try {
            await page.waitForFunction(() => /^[1-9]/.test(document.querySelector('#loading-status').textContent));
            assert.equal(await page.locator('#loading').isVisible(), true);
            if (mode === 'unknown') assert.equal(await page.locator('progress').getAttribute('value'), null);
            else {
              const value = await page.locator('progress').evaluate(el => el.value);
              assert.ok(value > 0 && value < 1, 'intermediate progress is observable');
            }
            await page.waitForFunction(() => window.gameReady);
            assert.equal(await page.evaluate(() => window.receivedWasm), true);
            const observed = await page.evaluate(() => window.byteText);
            assert.ok(observed.some(text => text.startsWith(wasm.length.toLocaleString('en-US') + ' bytes')), 'counts final decompressed byte total');
            assert.equal(await page.locator('#loading').isVisible(), false);
            await page.waitForFunction(() => canvas.width === 1600 && canvas.height === 1200);
            await page.setViewportSize({ width: 640, height: 480 });
            await page.waitForFunction(() => canvas.width === 1280 && canvas.height === 960);
            assert.deepEqual(errors, []);
          } finally { await page.close(); }
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

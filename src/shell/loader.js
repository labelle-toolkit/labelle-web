/* labelle-web: classic Emscripten Module hook, installed before game.js. */
(function (global) {
  'use strict';

  /** Install classic Emscripten startup hooks; optional canvas fitting needs CSS dimensions. */
  function install(module, options) {
    options = options || {};
    if (module.instantiateWasm) throw new Error('Module.instantiateWasm is already configured');
    const canvas = options.canvas || module.canvas;
    const overlay = options.overlay;
    const bar = options.progress;
    const status = options.status;
    const configured = Number(options.wasmBytes ?? overlay?.dataset.wasmBytes);
    const total = Number.isSafeInteger(configured) && configured > 0 ? configured : 0;
    let failed = false;
    let seen = 0;
    let frame;
    const previousReady = module.onRuntimeInitialized;
    const previousAbort = module.onAbort;

    /** Format decompressed byte counts independently of hosting compression. */
    function bytes(n) {
      return n.toLocaleString('en-US') + ' bytes';
    }
    /** Refresh determinate or indeterminate UI without changing failure state. */
    function progress() {
      if (failed) return;
      if (bar) {
        if (total) bar.value = Math.min(seen / total, 1);
        else bar.removeAttribute('value');
      }
      if (status) status.textContent = total
        ? bytes(seen) + ' / ' + bytes(total)
        : (seen ? bytes(seen) + ' downloaded' : 'Loading game…');
    }
    /** Catch script execution failures until the runtime takes over error reporting. */
    function startupError(event) {
      fail(event.error || new Error(event.message || 'Game startup failed'));
    }
    /** Display a terminal startup error, releasing temporary browser listeners. */
    function fail(error) {
      if (failed) return;
      failed = true;
      global.removeEventListener('error', startupError);
      cancelAnimationFrame(frame);
      if (overlay) {
        overlay.hidden = false;
        overlay.classList.add('failed');
        overlay.setAttribute('aria-busy', 'false');
      }
      if (bar) bar.hidden = true;
      if (status) {
        status.setAttribute('role', 'alert');
        status.textContent = 'Could not load the game. Check your connection and reload the page.';
      }
      console.error('LaBelle game loading failed:', error);
      options.onError?.(error);
    }
    /** Match the backing buffer to an independently sized CSS canvas. */
    function fit() {
      if (!canvas || failed) return;
      const dpr = global.devicePixelRatio || 1;
      const width = Math.max(1, Math.round(canvas.clientWidth * dpr));
      const height = Math.max(1, Math.round(canvas.clientHeight * dpr));
      if (canvas.width !== width) canvas.width = width;
      if (canvas.height !== height) canvas.height = height;
      // A backend may reset the buffer during init without changing its CSS box.
      frame = requestAnimationFrame(fit);
    }
    /** Forward one download stream while counting its decompressed bytes. */
    function count(body) {
      const reader = body.getReader();
      return new ReadableStream({
        async pull(controller) {
          try {
            const chunk = await reader.read();
            if (chunk.done) { controller.close(); return; }
            seen += chunk.value.byteLength;
            progress();
            controller.enqueue(chunk.value);
          } catch (error) { controller.error(error); }
        },
        cancel(reason) { return reader.cancel(reason); }
      });
    }
    global.addEventListener('error', startupError);
    module.canvas = canvas;
    module.instantiateWasm = function (imports, receiveInstance) {
      // locateFile retains project CDN/cache-busting choices. Override wasmURL
      // explicitly when the emitted filename is not game.wasm.
      Promise.resolve().then(() => {
        const url = options.wasmURL || (module.locateFile
          ? module.locateFile('game.wasm', options.scriptDirectory || '') : 'game.wasm');
        return fetch(url);
      }).then(async response => {
        if (!response.ok) throw new Error('HTTP ' + response.status);
        // Fetch exposes decompressed bytes: never use Content-Length as total.
        const counted = response.body ? new Response(count(response.body), {
          headers: { 'Content-Type': 'application/wasm' }
        }) : response;
        if (typeof WebAssembly.instantiateStreaming === 'function') {
          return WebAssembly.instantiateStreaming(counted, imports);
        }
        const buffer = await counted.arrayBuffer();
        if (!response.body) { seen = buffer.byteLength; progress(); }
        return WebAssembly.instantiate(buffer, imports);
      }).then(result => {
        if (status && !failed) status.textContent = 'Starting game…';
        receiveInstance(result.instance, result.module);
      }).catch(fail);
      return {}; // Emscripten completes through receiveInstance asynchronously.
    };
    module.onRuntimeInitialized = function () {
      try {
        previousReady?.apply(this, arguments);
        global.removeEventListener('error', startupError);
        if (!failed && overlay) {
          overlay.hidden = true;
          overlay.setAttribute('aria-busy', 'false');
        }
      } catch (error) { fail(error); throw error; }
    };
    module.onAbort = function (reason) {
      fail(reason);
      previousAbort?.apply(this, arguments);
    };
    module.labelleLoader = { fail, dispose() {
      cancelAnimationFrame(frame);
      global.removeEventListener('error', startupError);
    } };
    if (canvas) canvas.addEventListener('contextmenu', event => event.preventDefault());
    progress();
    // Custom canvases may size themselves from their backing attributes.
    // Fitting is opt-in and requires an independent CSS box (as in index.html).
    if (options.fitCanvas === true) fit();
    return module;
  }
  /**
   * Pick which build to load (labelle-web#24): `'threaded/'` when the page is
   * cross-origin isolated (so SharedArrayBuffer exists) AND an export shipped
   * a threaded build there (its `threaded/labelle-threads.json` marker); `''` (the build beside the page) otherwise. A
   * threaded module fails to start without isolation, so the fallback is the
   * single-threaded build at the root. `labelle run` with threads serves its
   * threaded build at the root, isolated, so this answers `''` there too.
   * Calls `done(base)` exactly once; never rejects.
   */
  function pickBuild(done) {
    if (!(global.crossOriginIsolated && typeof SharedArrayBuffer !== 'undefined') || typeof fetch !== 'function') {
      done('');
      return;
    }
    // An explicit marker, not a probe for threaded/game.js: hosts that answer
    // any missing path with the index page (status 200) would fool that.
    fetch('threaded/labelle-threads.json', { cache: 'no-store' })
      .then(response => (response.ok ? response.json() : null))
      .then(marker => done(marker && marker.labelle_threads === 1 ? 'threaded/' : ''), () => done(''));
  }
  global.LabelleLoader = { install, pickBuild };
})(globalThis);

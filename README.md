# labelle-web

Web platform package for the Labelle toolkit.

## Status

IndexedDB blob storage is implemented in `src/web_storage.c` with Zig bindings in `src/web_storage.zig`. The backend adds the C source with its emscripten sysroot and imports the `storage` module. Runtime service selection remains explicit. The default loading shell and its staging API/tool are implemented; automatic CLI export/serve integration, toolchain provisioning, and provider commands remain extraction work.

## Planned responsibilities

- Web toolchain provisioning and build orchestration through the generic provider contract.
- Local serving, export orchestration, compression, and size reporting.
- Browser storage services through the engine's storage interface.

The provider target remains `wasm`. Backend-specific rendering and emscripten linking remain with backend packages. Custom game pages must remain supported. A default package selection is registry/scaffold data, not a hardcoded CLI package name.

## Implementation references

- [Provider architecture: CLI #406](https://github.com/labelle-toolkit/labelle-cli/issues/406)
- [Contract decisions before implementation: CLI #411](https://github.com/labelle-toolkit/labelle-cli/issues/411)
- [Manifest-declared texture capabilities: CLI #407](https://github.com/labelle-toolkit/labelle-cli/issues/407)
- [Default loading shell: CLI #402](https://github.com/labelle-toolkit/labelle-cli/issues/402)
- [Fullscreen canvas sizing: bgfx #130](https://github.com/labelle-toolkit/labelle-bgfx/issues/130)
- [Persistent browser saves: engine #893](https://github.com/labelle-toolkit/labelle-engine/issues/893)

Migration is breaking: existing web projects explicitly add and pin the provider. Introduce the package manifest after the contract decisions are settled. Verify browser startup, resize/fullscreen, custom-shell behavior, and save persistence when those features land.

## Default browser shell

The shell shows the LaBelle logo, a progress bar and a byte counter while the
browser downloads and compiles `game.wasm`. Fetch counts **decompressed** bytes,
so the total is the raw file size even with gzip/Brotli hosting. Compilation
streams from the same counted response; browsers without `instantiateStreaming`
use a buffered fallback. Without a known size the bar is indeterminate. The
loader hides on `Module.onRuntimeInitialized` and reports JS/download/compile/
abort failures visibly. The canvas follows its CSS size and devicePixelRatio,
including backend buffer resets during startup. Reduced-motion preferences stop
the logo pulse.

Stage an existing web build (Zig 0.16.0):

```sh
zig build shell -- /absolute/path/to/built/web /absolute/path/to/project/web
# Omit the second directory when there is no project web directory.
# Or install a reusable host tool:
zig build install-shell
zig-out/bin/labelle-web-shell /absolute/path/to/built/web
```

This adds `index.html`, `labelle-loader.js` and `labelle-logo.png`. Those two
`labelle-*` filenames are reserved and replaced on every staging call. Other
files, including `game.html`, remain untouched. The tool operates on an existing
build/staging directory; it does not build a game or copy custom page assets.
Use `labelle build` to build games, then run this tool against the web output.
For an exported directory, stage **after wasm-opt/other wasm changes and before
precompression or zipping**. No deploy-script size substitution is needed.

Page precedence is project `web/index.html`, then an emitted `index.html`, then
the package default (ahead of emcc's `game.html`). Custom HTML is preserved apart
from explicit `__WASM_BYTES__` placeholders, which become the actual raw
`game.wasm` length, or `0` if absent. Pass the original project web directory on
every staging call so custom placeholders are freshly substituted; copied custom
pages with an already substituted value cannot be restamped without their source.
The package default is recognized by its leading marker and restamped on rebuild.

### Reuse the loader in a custom page

Load `labelle-loader.js` before `game.js`, then configure the existing Module:

```html
<div id="loading" data-wasm-bytes="__WASM_BYTES__" aria-busy="true">
  <progress id="progress" max="1" aria-label="Downloading game"></progress>
  <p id="status" role="status">Loading game…</p>
</div>
<script src="labelle-loader.js"></script>
<script>
  var Module = LabelleLoader.install(window.Module || {}, {
    canvas: document.getElementById('canvas'),
    overlay: document.getElementById('loading'),
    progress: document.getElementById('progress'),
    status: document.getElementById('status')
  });
</script>
<script src="game.js" onerror="Module.labelleLoader.fail(new Error('game.js download failed'))"></script>
```

Your page supplies its own styles and canvas (the default page is an example).
For loader-script download failures, copy the inline `labelleShellFail` fallback
and guarded game-script startup from `src/shell/index.html`; that fallback works
even when `LabelleLoader` is unavailable.
Existing `onRuntimeInitialized`, `onAbort` and `locateFile` callbacks are retained.
The loader owns `instantiateWasm`; installation rejects an existing override.
Options include `wasmURL` (otherwise `locateFile('game.wasm', scriptDirectory)` or
`game.wasm`), `scriptDirectory`, `wasmBytes` (overrides the data attribute),
`fitCanvas: true` and `onError`. Canvas fitting is **off by default** for custom
pages: enable it only when CSS supplies width and height independently of the
canvas backing attributes (for example, `width: 100vw; height: 100dvh`). The
default shell supplies that CSS and explicitly enables fitting. URLs resolve relative to the document; pass an
explicit URL/prefix for CDN/subdirectory glue. `Module.labelleLoader.dispose()`
stops canvas fitting when a custom page removes the game. This hook supports
classic Emscripten `Module` builds, not modularized factories/ES modules or
pthread worker bootstrap.

### Provider integration boundary

`b.dependency("labelle_web", ...).module("shell")` exposes
`shell.stage(allocator, io, output_dir, project_web_dir)`, returning the selected
page source and optional wasm byte count. Both directory arguments are open
`std.Io.Dir` handles (the project directory is nullable). The same API is intended
for local serve and export; stage custom assets first and pass their original
source directory. I/O errors propagate instead of silently falling back.

This PR delivers the shell portion of CLI #402 inside `labelle-web`, per CLI
#406. It does **not** yet make `labelle init`, `wasm export`, or `wasm serve`
select this package automatically. The remaining web-provider extraction must
call this API at the points above and preserve project page precedence. No CLI
platform special case or premature target ownership is added here.

### Validation

`zig build test install-shell` checks the Zig bindings, staging precedence,
size substitution, restamping and invalid inputs, and builds the host tool.

```sh
cd tests/shell
npm ci --ignore-scripts
npx playwright install chromium firefox webkit
npm test
```

Browser tests throttle a valid wasm download and exercise byte progress, gzip,
unknown size, buffered fallback, errors, callback preservation and canvas sizing
in Chromium, Firefox and WebKit. CI also compiles `tests/shell/main.c` with
Emscripten 4.0.9 and verifies that its actual glue reaches `main` through the shell.
Set `EMCC_FIXTURE` to that output directory to repeat the real-glue test locally.
The logo is copied from `labelle-assembler/src/assets/default_icon.png`.

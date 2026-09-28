# labelle-web

Web platform package for the Labelle toolkit.

## Status

IndexedDB blob storage is implemented in `src/web_storage.c` with Zig bindings in `src/web_storage.zig`. The backend adds the C source with its emscripten sysroot and imports the `storage` module. Runtime service selection remains explicit. The default loading shell and its staging API/tool are implemented. The provider (contract 1.3, labelle-cli 2.1.0+) provisions the emscripten toolchain, defaults `wasm` builds to ReleaseSafe, stages build output, serves it (with browser live reload under `labelle run --watch`), exports it, and checks its requirements (`labelle web doctor`).

## Responsibilities

- Web toolchain provisioning (emsdk) through the generic provider contract.
- HTTP serving, browser reload and export of `wasm` builds.
- Browser storage services through the engine's storage interface.

The provider target remains `wasm`. Backend-specific rendering and emscripten linking remain with backend packages; building and file watching remain with the CLI. Custom game pages must remain supported. A default package selection is registry/scaffold data, not a hardcoded CLI package name.

## Implementation references

- [Provider architecture: CLI #406](https://github.com/labelle-toolkit/labelle-cli/issues/406)
- [Contract decisions before implementation: CLI #411](https://github.com/labelle-toolkit/labelle-cli/issues/411)
- [Manifest-declared texture capabilities: CLI #407](https://github.com/labelle-toolkit/labelle-cli/issues/407)
- [Default loading shell: CLI #402](https://github.com/labelle-toolkit/labelle-cli/issues/402)
- [Fullscreen canvas sizing: bgfx #130](https://github.com/labelle-toolkit/labelle-bgfx/issues/130)
- [Persistent browser saves: engine #893](https://github.com/labelle-toolkit/labelle-engine/issues/893)
- [Web/wasm leaves the CLI core: CLI #466](https://github.com/labelle-toolkit/labelle-cli/issues/466) (this is its PR W)

Migration is breaking: existing web projects explicitly add and pin the provider. Verify browser startup, resize/fullscreen, custom-shell behavior, and save persistence when those features land.

## Default browser shell

The shell shows the LaBelle logo, a progress bar and a byte counter while the
browser downloads and compiles `game.wasm`. Fetch counts **decompressed** bytes,
so the total is the raw file size even with gzip/Brotli hosting. Compilation
streams from the same counted response; browsers without `instantiateStreaming`
use a buffered fallback. Without a known size the bar is indeterminate. The
loader hides on `Module.onRuntimeInitialized` and reports JS/download/compile/
abort failures visibly. Temporary window error handling also catches game-script
syntax errors and synchronous startup exceptions, and is removed once the runtime
initializes (later game errors do not reopen the loading screen). The canvas follows its CSS size and devicePixelRatio,
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

The provider uses this API automatically after build and before serving/export.
Its private `.labelle-shell-state.json` tracks copied custom files and the original emitted page so
repeated staging restamps it and removing a project override restores the
emitted/default page. Deleted custom files are removed when their staged bytes
still match the last copy; newly emitted backend replacements are preserved.
The server hides this file; exports omit it.

## CLI provider

Requires Zig 0.16.0 and labelle-cli 2.1.0 or newer: the manifest admits
provider contract 1.3.x (`command_contract = ">=1.3.0 <1.4.0"`; a patch wire
adds no keys, and the decoder still rejects unknown fields), whose
`cache_dir`, `env_file` and `run.watch` it uses. Add this package explicitly
to `project.labelle`'s `.plugins`, using a pinned release or commit (a
`local:/absolute/path/to/labelle-web` checkout works too). The dependency name
is `web`; the repository is `labelle-toolkit/labelle-web`. For remote pins,
run `labelle providers resolve`, review the proposed pins, then repeat with
`--accept` to update the lock. The package claims target `wasm` and namespace
`web`; do not declare another owner for the same target/namespace.

```sh
labelle build --platform=wasm              # provision emsdk, build (ReleaseSafe), stage the sized shell
labelle run --platform=wasm -- --port=9000 --no-open   # build, stage, and serve
labelle run --platform=wasm --watch        # serve, rebuild on change, reload the browser
labelle bundle --platform=wasm             # build and package through the hook
labelle web serve --port=8080 --no-open    # serve an existing build
labelle web export --output=dist --zip --platform=github-pages
labelle web doctor [--json]                # Python + emsdk requirements
labelle web toolchain which                # which emsdk the next build uses
labelle web toolchain install [<version>]  # install the managed emsdk ahead of a build
```

| Hook | Slot | Does |
| --- | --- | --- |
| `toolchain` | before `generate` | Resolves (and, managed, installs) the emsdk and writes `env_file` |
| `toolchain-package` | after `generate` | Package mode only: activates every `zig-pkg/*/emsdk` in place |
| `shell` | after `build` | Stages the loading shell into `zig-out/web` |
| `serve` | replaces `run` (`.watch = true`) | Serves the build; in a watch session, the published output |
| `export` | replaces `bundle` | Packages the build into the bundle directory |

The manifest's `target_defaults` makes `wasm` builds ReleaseSafe unless
`--optimize` (or `--release`) says otherwise.

### Emscripten toolchain

The `toolchain` hook runs before generation, so its contribution reaches the
CLI's generation-time fingerprint pass (`zig build --list-steps`), the compile
and every later hook. It writes `env_file` with `EMSDK`, `EM_CONFIG` (when the
emsdk has one) and `upstream/emscripten` in front of `PATH`. The backends
(bgfx, sokol, raylib) link with `$EMSDK/upstream/emscripten/emcc` whenever
it exists, so every backend shares one emsdk.

Which emsdk, by settings `emsdk.source`:

1. `managed` (default): an inherited `EMSDK` that is an activated emsdk
   (both `upstream/emscripten/emcc` and the `.emscripten` config exist) is
   passed through untouched; otherwise `emsdk.root`; otherwise the
   provider-managed install, fetched on first use: `git clone --depth 1
   --branch <version>` of emscripten-core/emsdk, the pinned commit verified
   (4.0.9 is `3bcf1dcd`; another version is trusted by tag), then `emsdk
   install` and `emsdk activate`.
2. `inherited`: only the inherited `EMSDK`; `root`: only `emsdk.root`. Either
   fails instead of falling back, including when the emsdk has emcc but no
   `.emscripten` (an interrupted activation: run `emsdk activate`).
3. `package`: the emsdk the backends' Zig dependency fetched into
   `<target>/zig-pkg/` is activated in place after generation, every copy of
   it (a graph holding two emsdk hashes builds with either), and the one the
   target's `build.zig.zon` names is contributed from the compile onward.
   The provider records the version it activated in each tree
   (`.labelle-web-activated`); a tree activated for another `emsdk.version`,
   or by someone else (CLI 2.x activates one copy itself), is re-activated for
   the requested version (`emsdk install` adds it, `emsdk activate` switches
   to it). Offline, that re-activation is refused.

The managed install lives in the provider's cache (the CLI's `cache_dir`,
`<LABELLE_HOME>/providers/<provider id>/`), shared by every project that pins
this provider:

```
<cache_dir>/emsdk/v1/<arch>-<os>/<version>-<commit12>/   an activated emsdk (~1 GB)
```

Installs are keyed by host and SDK identity, serialized by a file lock beside
the directory, built in a staging sibling and renamed into place with a
completion marker, so two builds installing one version at once end with one
valid install. With `LABELLE_OFFLINE` set a missing install fails naming the
version; a cached one is used without network. The old CLI cache
(`~/.labelle/emsdk/`) is neither migrated nor deleted; remove it yourself once
no CLI 2.x project needs it.

emsdk and emcc need Python 3 on `PATH` (`python3`; `python`, then `python3`,
on Windows). The provider runs the candidate and accepts only Python 3; a
Python 2, or none, fails the hooks with the fix: `labelle install python` (the
CLI's managed interpreter) or a system Python 3. On Windows the verified
command is also passed as `EMSDK_PYTHON` to `emsdk.bat` and contributed to the
build, so `emcc.bat` runs the same interpreter.

`labelle web doctor` reports both requirements without installing anything and
exits non-zero only when one is missing; `labelle doctor` runs it after the core
checks. `--json` prints one line, the `wasm` capability object
`{"id":"wasm","required":true,"ok":…,"items":[python, emsdk]}` whose items keep
labelle-studio's shape (`id`, `name`, `ok`, `fixable`, `size_mb`, `action`,
`detail`, `hint`).

### Browser watch

`labelle run --platform=wasm --watch` keeps the `serve` replacement running
while the CLI watches the project and rebuilds. The CLI publishes each fully
successful build (every hook included) into a fresh directory, switches
`run.watch.output_dir` to it, then advances `run.watch.generation_file`. The
server serves only `output_dir` (resolved afresh for each request, never the
staging tree), polls the generation file and, when it changes, open pages
reload through the injected client polling `/__labelle_livereload`. Each page
is served with the generation it came from embedded in that client, so a
build published between serving the page and its first poll still reloads it. A failed
rebuild publishes nothing, so the last good build keeps being served. SIGTERM or
Ctrl+C stops the server with status 0.

### Serving and exporting

Provider commands consume existing build output. They discover exactly one
`.labelle/*_wasm/zig-out/web` directory containing `game.wasm`; use
`--input=/absolute/path/to/web` when multiple backends have been built.
`game.js` and `game.wasm` are required with exactly that casing. Symlinked
build artifacts are rejected before staging, serving, or export. Arguments use `--name=value` syntax;
export platform is optional (`itch` or `github-pages`). GitHub Pages export
adds `.nojekyll`. ZIP archives contain the final staged files. The writer supports ZIP32
(up to 65,535 entries and a 4 GiB archive); larger archives return `Zip64Required`.
The `serve` hook reads `--port=N` and `--no-open` from the arguments after
`labelle run ... --`.

`labelle run` options (`--scene`, `--profile`, `--screenshot`, `--after`)
reach the `serve` hook as `run.env` (`LABELLE_SCENE`, ...). A browser game
has no process environment, so every served HTML page gets them in a script
placed first in `<head>`: `window.LABELLE_RUN_ENV = {"LABELLE_SCENE": "intro"}`,
plus a `Module.preRun` step that copies them into Emscripten's `ENV` before
`main`. The game's `getenv` then sees them as on desktop; the engine's
`requestedScene()` reads `LABELLE_SCENE` through `getenv`. The script extends
an existing `Module` (or creates one), which classic Emscripten glue and
`LabelleLoader.install(window.Module || {})` both keep. Custom pages may also
read `window.LABELLE_RUN_ENV` directly.

Project `web/` resources are copied alongside the selected page. Root filenames
`game.js`, `game.wasm`, `game.data`, `.labelle-export`, `labelle-loader.js`, `labelle-logo.png` and
`.labelle-shell-state.json` are reserved (including case variants and compressed siblings); custom assets
cannot replace them.
Precompressed custom files are ignored when the original file is present;
regenerate compression after export. Exports run optional `wasm-opt` before size stamping, invalidate stale compressed
copies of changed artifacts, and report the shipped tree. Destination paths
cannot overlap inputs or replace the project/custom-page directory; unrelated
nonempty directories are refused. An existing ZIP is replaced only when its
SHA-256 matches the ownership record from an earlier export; unrelated or
modified neighboring archives are refused before the output directory changes.

### Settings

Map a provider-owned JSON file in `project.labelle`:

```zig
.provider_config = .{
    .{ .package = "web", .file = "providers/web.json" },
},
```

Schema 1, strict (unknown keys, duplicate keys and wrong types are errors).
Only `schema_version` is required; the other values shown are the defaults:

```json
{ "schema_version": 1, "port": 8080, "open_browser": true, "build_dir": null,
  "emsdk": { "version": "4.0.9", "source": "managed", "root": null },
  "export": { "platform": "none", "zip": false } }
```

`build_dir` selects existing output for the `serve`/`export` commands; the hooks
receive the current target output directly. `emsdk.root` may be relative to the
project. `export.platform` is `none`, `itch` or `github-pages`. Command flags and
`run` arguments override settings. Upgrading from v0.2.0: add
`"schema_version": 1` to an existing settings file.

### Stdout

Under `--progress=json` the CLI's stdout carries only its NDJSON feed, so the
provider writes diagnostics (and the output of `git` and `emsdk`) to stderr,
with streaming writers that append correctly when both streams go to one file.
Only a command's answer (`toolchain which`, `doctor --json`) uses stdout.

### Validation

`zig build test install-shell install-provider` checks the Zig bindings, staging precedence,
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

Provider integration checks use a CLI built from labelle-cli v2.1.0:

```sh
python3 tests/provider/e2e.py --cli /absolute/path/to/labelle --zig /absolute/path/to/zig
python3 tests/provider/toolchain_e2e.py --cli /absolute/path/to/labelle --zig /absolute/path/to/zig
```

The first exercises real command discovery/export/HTTP serving and strict build/bundle
hook contexts, custom-page removal, final optimized size stamping, ZIP contents,
multiple-backend selection, and destructive-path rejection. The second runs the
toolchain and watch hooks through the real pipeline with a fake assembler and a
fake emsdk (no network): the managed install reaching the fingerprint pass and
the compile, external-`EMSDK` passthrough, offline hits and misses, missing
Python, a concurrent install race, package mode, `doctor --json`, `--progress=json`
stdout purity, and live reload with failed-build preservation.

CI's `wasm-from-zero` job builds a fresh `labelle init` project for `wasm` on
Linux, macOS and Windows with a clean `LABELLE_HOME`, `EMSDK` unset and no emcc
on `PATH`, so the provider really provisions emsdk; a second step sets an
external `EMSDK` and asserts it is passed through without a download.

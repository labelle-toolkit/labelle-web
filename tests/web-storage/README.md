# IndexedDB bridge tests (engine #893)

Run `npm ci --ignore-scripts` and `npm test` here. The test loads the actual
factory between the marked comments in `src/web_storage.c`, then exercises it
with fake-indexeddb 6.2.5. Node's Blob supplies the binary payload implementation.

Six tests cover multi-save/list/delete, copying input before return, reopening
the database from a fresh runtime, metadata independence, overwrite, missing
and oversized reads, access/quota/unavailable failures, transaction abort after
request success, concurrent ordering, namespace isolation, dropped observers,
a synthetic 16 MiB blob, blocked database opens and malformed stored records. This is simulated IndexedDB evidence, not browser
or device acceptance. No real FP save size or browser frame time was measured.

`src/web_storage.zig` is the engine Web adapter's binding module. Plain C
wrappers keep the EM_JS imports reachable when the object is eventually linked
from a static archive. Zig's adapter/binding combination is compile-checked for
wasm32-emscripten in the paired engine checkout; emcc linking is not tested.

The package exports storage bindings and the C implementation. The bgfx integration adds this module and compiles the C source in its wasm build only. Provider command/target resolution is separate work. Completion follows the IndexedDB transaction, not the individual request.

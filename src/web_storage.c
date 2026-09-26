// IndexedDB blob storage for engine#893. Backend builds attach the emscripten
// sysroot and compile this source; storage semantics belong to labelle-web.
// Plain C wrappers make EM_JS code reachable when linked from a static archive.
#include <emscripten/em_js.h>
#include <stdint.h>

EM_JS(void, labelle_blob_init_js, (), {
    // BEGIN TESTABLE STORAGE FACTORY
    function createLabelleBlobStorage(idb) {
        const operations = new Map();
        const databases = new Map();
        let nextId = 1;
        const code = e => ({
            NotFoundError: -1, QuotaExceededError: -2,
            InvalidStateError: -3, SecurityError: -4, NotAllowedError: -4,
            TooLargeError: -5
        }[e && e.name] || -6);
        function open(namespace) {
            if (!idb) return Promise.reject({ name: 'InvalidStateError' });
            if (databases.has(namespace)) return databases.get(namespace);
            const promise = new Promise((resolve, reject) => {
                let blocked = false;
                const request = idb.open('labelle.blobs.' + namespace, 1);
                request.onupgradeneeded = () => request.result.createObjectStore('blobs', { keyPath: 'name' });
                request.onerror = () => reject(request.error);
                request.onblocked = () => { blocked = true; reject({ name: 'InvalidStateError' }); };
                request.onsuccess = () => {
                    const db = request.result;
                    if (blocked) { db.close(); return; }
                    const evict = () => { if (databases.get(namespace) === promise) databases.delete(namespace); };
                    db.onversionchange = () => { db.close(); evict(); };
                    db.onclose = evict;
                    resolve(db);
                };
            });
            databases.set(namespace, promise);
            promise.catch(() => { if (databases.get(namespace) === promise) databases.delete(namespace); });
            return promise;
        }
        function begin(namespace, kind, name, input, maxBytes) {
            // Copy before returning: wasm memory and callers' buffers can be
            // reused/grown as soon as begin returns.
            const bytes = kind === 1 ? new Blob([input]) : null;
            if (nextId > 0xffffffff) return 0; // never alias a live handle
            const id = nextId++;
            const operation = { status: 0, bytes: new Uint8Array() };
            operations.set(id, operation);
            open(namespace).then(db => {
                if (kind < 0 || kind > 3) throw new Error('invalid operation');
                const tx = db.transaction('blobs', kind === 1 || kind === 3 ? 'readwrite' : 'readonly', { durability: 'strict' });
                const store = tx.objectStore('blobs');
                let failure = null;
                let value = null;
                const entries = [];
                tx.onabort = () => { operation.status = code(failure || tx.error); };
                tx.onerror = () => { failure = tx.error; };
                tx.oncomplete = () => {
                    try {
                    // Request success is NOT durability. This is the only
                    // path to success, after the whole transaction commits.
                    if (failure) { operation.status = code(failure); return; }
                    if (kind === 0) {
                        if (!value) { operation.status = -1; return; }
                        if (value.bytes.size > maxBytes) { operation.status = -5; return; }
                        value.bytes.arrayBuffer().then(buffer => {
                            operation.bytes = new Uint8Array(buffer);
                            operation.status = 1;
                        }).catch(e => { operation.status = code(e); });
                    } else {
                        if (kind === 2) operation.bytes = new TextEncoder().encode(JSON.stringify(entries));
                        operation.status = 1;
                    }
                    } catch (e) { operation.status = code(e); }
                };
                if (kind === 0) {
                    const request = store.get(name);
                    request.onsuccess = () => { value = request.result; };
                } else if (kind === 1) {
                    store.put({ name: name, bytes: bytes, modified_ms: Date.now() });
                } else if (kind === 2) {
                    const request = store.openCursor();
                    request.onsuccess = () => {
                        try {
                        const cursor = request.result;
                        if (!cursor) return;
                        const record = cursor.value;
                        entries.push({ name: record.name, size: record.bytes.size, modified_ms: record.modified_ms });
                        cursor.continue();
                        } catch (e) { failure = e; tx.abort(); }
                    };
                } else store.delete(name);
            }).catch(e => { operation.status = code(e); });
            return id;
        }
        return {
            begin: begin,
            status: id => operations.has(id) ? operations.get(id).status : -3,
            data: id => operations.get(id).bytes,
            release: id => operations.delete(id),
            close: async () => {
                for (const promise of databases.values()) { try { (await promise).close(); } catch (_) {} }
                databases.clear();
            }
        };
    }
    // END TESTABLE STORAGE FACTORY
    if (!globalThis.__labelleBlobs) {
        let idb;
        try { idb = globalThis.indexedDB; } catch (_) {}
        globalThis.__labelleBlobs = createLabelleBlobStorage(idb);
    }
});

EM_JS(uint32_t, labelle_blob_begin_js, (const char *ns, uint32_t ns_len, uint32_t kind, const char *name, uint32_t name_len, const uint8_t *data, uint32_t data_len, uint32_t limit), {
    try {
        return globalThis.__labelleBlobs.begin(UTF8ToString(ns, ns_len), kind,
            UTF8ToString(name, name_len), HEAPU8.subarray(data, data + data_len), limit);
    } catch (_) { return 0; }
});
EM_JS(int32_t, labelle_blob_status_js, (uint32_t id), {
    return globalThis.__labelleBlobs.status(id);
});
EM_JS(uint32_t, labelle_blob_length_js, (uint32_t id), {
    return globalThis.__labelleBlobs.data(id).length;
});
EM_JS(int32_t, labelle_blob_copy_js, (uint32_t id, uint8_t *out, uint32_t len), {
    const data = globalThis.__labelleBlobs.data(id);
    if (data.length !== len) return 0;
    HEAPU8.set(data, out);
    return 1;
});
EM_JS(void, labelle_blob_release_js, (uint32_t id), {
    globalThis.__labelleBlobs.release(id);
});

uint32_t labelle_blob_begin(const char *ns, uint32_t ns_len, uint32_t kind, const char *name, uint32_t name_len, const uint8_t *data, uint32_t data_len, uint32_t limit) {
    labelle_blob_init_js();
    return labelle_blob_begin_js(ns, ns_len, kind, name, name_len, data, data_len, limit);
}
int32_t labelle_blob_status(uint32_t id) { return labelle_blob_status_js(id); }
uint32_t labelle_blob_length(uint32_t id) { return labelle_blob_length_js(id); }
int32_t labelle_blob_copy(uint32_t id, uint8_t *out, uint32_t len) { return labelle_blob_copy_js(id, out, len); }
void labelle_blob_release(uint32_t id) { labelle_blob_release_js(id); }

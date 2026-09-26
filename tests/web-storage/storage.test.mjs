import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
import assert from 'node:assert/strict';
import { IDBFactory } from 'fake-indexeddb';

// Test the actual EM_JS implementation, not a parallel JS copy.
const source = readFileSync(new URL('../../src/web_storage.c', import.meta.url), 'utf8');
const factorySource = source.split('// BEGIN TESTABLE STORAGE FACTORY')[1].split('// END TESTABLE STORAGE FACTORY')[0];
const create = vm.runInNewContext(factorySource + '; createLabelleBlobStorage', { Blob, TextEncoder, Uint8Array, Map, Date, Promise });
const bytes = text => new TextEncoder().encode(text);
const text = data => new TextDecoder().decode(data);
async function settle(api, id) {
    const deadline = Date.now() + 5000;
    while (api.status(id) === 0) {
        if (Date.now() > deadline) throw Error('operation never settled');
        await new Promise(resolve => setTimeout(resolve, 1));
    }
    return api.status(id);
}
async function run(api, kind, name = '', data = new Uint8Array(), limit = 1e6) {
    const id = api.begin('test-game', kind, name, data, limit);
    assert.equal(await settle(api, id), 1);
    const result = api.data(id);
    api.release(id);
    return result;
}

test('multiple saves, copied input, reopen/reload, overwrite, sidecars, list and delete', async () => {
    const idb = new IDBFactory();
    let api = create(idb);
    const input = bytes('original');
    const id = api.begin('test-game', 1, 'a.json', input, 0);
    assert.equal(api.status(id), 0);
    input.fill(0);
    assert.equal(await settle(api, id), 1);
    api.release(id);
    await run(api, 1, 'a.meta', bytes('{"day":7}'));
    await run(api, 1, 'b.json', bytes('second'));
    await api.close();
    api = create(idb); // fresh runtime, same persistent IndexedDB factory
    assert.equal(text(await run(api, 0, 'a.json')), 'original');
    const listed = JSON.parse(text(await run(api, 2)));
    assert.deepEqual(listed.map(e => e.name), ['a.json', 'a.meta', 'b.json']);
    assert.equal(listed[0].size, 8);
    assert.ok(listed[0].modified_ms > 0);
    await run(api, 1, 'a.json', bytes('new'));
    assert.equal(text(await run(api, 0, 'a.json')), 'new');
    await run(api, 3, 'a.json');
    await run(api, 3, 'a.json');
    const missing = api.begin('test-game', 0, 'a.json', new Uint8Array(), 100);
    assert.equal(await settle(api, missing), -1);
    api.release(missing);
    assert.equal(text(await run(api, 0, 'a.meta')), '{"day":7}');
    const small = api.begin('test-game', 0, 'b.json', new Uint8Array(), 2);
    assert.equal(await settle(api, small), -5);
    api.release(small);
    await api.close();
});

test('no IndexedDB, denied access and quota errors are observable', async () => {
    for (const [idb, expected] of [
        [undefined, -3],
        [{ open() { throw new DOMException('denied', 'SecurityError'); } }, -4],
        [{ open() { throw new DOMException('quota', 'QuotaExceededError'); } }, -2],
    ]) {
        const api = create(idb);
        const id = api.begin('test-game', 1, 'a.json', bytes('data'), 0);
        assert.equal(await settle(api, id), expected);
        api.release(id);
        await api.close();
    }
});

test('request success followed by transaction abort is never reported saved', async () => {
    // A deterministic transaction double simulates a quota abort AFTER the
    // put request succeeded, the critical false-durability regression.
    let transaction;
    const request = {};
    const api = create({ open() {
        queueMicrotask(() => request.onsuccess());
        request.result = { close() {}, transaction() {
            transaction = { objectStore() { return { put() { return {}; } }; } };
            return transaction;
        } };
        return request;
    } });
    const id = api.begin('test-game', 1, 'a.json', bytes('data'), 0);
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(api.status(id), 0);
    transaction.error = new DOMException('quota', 'QuotaExceededError');
    transaction.onabort();
    assert.equal(await settle(api, id), -2);
    api.release(id);
    await api.close();
});

test('concurrent writes preserve submission order, namespaces isolate and release does not cancel', async () => {
    const api = create(new IDBFactory());
    const first = api.begin('test-game', 1, 'a.json', bytes('first'), 0);
    const last = api.begin('test-game', 1, 'a.json', bytes('last'), 0);
    api.release(first);
    assert.equal(await settle(api, last), 1);
    api.release(last);
    assert.equal(text(await run(api, 0, 'a.json')), 'last');
    const other = api.begin('other-game', 0, 'a.json', new Uint8Array(), 100);
    assert.equal(await settle(api, other), -1);
    api.release(other);
    await api.close();
});

test('large blob round-trip uses binary bytes and listing carries only metadata', async () => {
    const api = create(new IDBFactory());
    const input = new Uint8Array(16 * 1024 * 1024);
    for (let i = 0; i < input.length; i += 4096) input[i] = (i / 4096) % 251;
    await run(api, 1, 'large.json', input);
    const output = await run(api, 0, 'large.json', new Uint8Array(), input.length);
    assert.deepEqual(output, input);
    const list = await run(api, 2);
    assert.ok(list.length < 200);
    assert.equal(JSON.parse(text(list))[0].size, input.length);
    await api.close();
});

test('blocked opens and malformed stored records terminate with errors rather than hanging', async () => {
    let closed = false;
    const request = { result: { close() { closed = true; } } };
    const blocked = create({ open() {
        queueMicrotask(() => { request.onblocked(); request.onsuccess(); });
        return request;
    } });
    const blockedId = blocked.begin('test-game', 2, '', new Uint8Array(), 0);
    assert.equal(await settle(blocked, blockedId), -3);
    assert.equal(closed, true);
    blocked.release(blockedId);

    const idb = new IDBFactory();
    const api = create(idb);
    await run(api, 1, 'a.json', bytes('initial'));
    await new Promise((resolve, reject) => {
        const open = idb.open('labelle.blobs.test-game', 1);
        open.onerror = () => reject(open.error);
        open.onsuccess = () => {
            const db = open.result;
            const tx = db.transaction('blobs', 'readwrite');
            tx.objectStore('blobs').put({ name: 'a.json', modified_ms: 1 }); // missing Blob
            tx.oncomplete = () => { db.close(); resolve(); };
            tx.onabort = () => { db.close(); reject(tx.error); };
        };
    });
    for (const kind of [0, 2]) {
        const id = api.begin('test-game', kind, 'a.json', new Uint8Array(), 100);
        assert.equal(await settle(api, id), -6);
        api.release(id);
    }
    await api.close();
});

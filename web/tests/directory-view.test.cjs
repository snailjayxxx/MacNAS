"use strict";
const test = require("node:test"), assert = require("node:assert/strict");
const M = require("../dist/model.js"), C = require("../dist/bridge-client.js"), F = require("../dist/directory-view.js"), P = require("../dist/task-pages.js"), N = require("../dist/notification-view.js");
const code = value => error => error instanceof M.ServiceError && error.code === value;
const token = n => "20000000-0000-0000-0000-" + n.toString(16).padStart(12, "0");
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
const info = { apiVersion: 1, source: "fixture-host", userID: "fixture-owner", role: "administrator", mode: "synthetic_development", databaseSchema: 3, physicalPool: "unbound", languages: ["zh-CN", "ja-JP"], active: 0, completed: 0, logicalReferenceBytes: 0, taskTimestampsAvailable: false, libraries: [] };
const item = (name, parent = "", kind = "file") => ({ name, relativePath: (parent ? parent + "/" : "") + name, kind, modifiedAt: "2026-10-15T00:00:00Z", ...(kind === "file" ? { bytes: 1 } : {}) });
const page = (p, items = [item("a.txt", p.relativePath)], nextCursor = null) => ({ pageVersion: 1, order: "name-utf8", consistency: "directory-stamped-live-metadata", libraryID: p.libraryID, relativePath: p.relativePath, pageSize: p.pageSize, items, nextCursor });
async function setup(scenario = "owner", options) {
  const api = M.createFixtureAdapter(), session = await api.beginFixtureSession(scenario), source = await F.createFixtureDirectorySource(api, session, options);
  return { api, session, source, pager: F.createDirectoryPager({ source, pageSize: 3 }) };
}
function provider(overrides = {}) {
  const calls = [], discarded = [];
  return { source: "fixture-host-client", closed: false, calls, discarded,
    overview: async () => info, listLibraries: async () => [{ libraryID: "literal", volumeID: token(1), estimatedBytes: 123, state: "missing" }],
    listFilesPage: async p => { calls.push(p); return page(p); }, previewFile: async p => ({ libraryID: p.libraryID, relativePath: p.relativePath, text: "x", utf8Bytes: 1 }),
    discardFilePage: value => { discarded.push(value); return true; }, close() { this.closed = true; }, ...overrides };
}
test("directory sources require an explicit supported provider and never construct a fallback", async () => {
  for (const value of [undefined, {}, M.createFixtureAdapter()]) await assert.rejects(F.createClientDirectorySource(value), code("unavailable"));
  await assert.rejects(F.createFixtureDirectorySource({}, {}), code("unavailable"));
  assert.throws(() => F.createDirectoryPager({ source: {}, pageSize: 2 }), code("invalidInput"));
  const { source } = await setup();
  for (const size of [null, 0, true, 101]) assert.throws(() => F.createDirectoryPager({ source, pageSize: size }), code("invalidInput"));
});
test("fixture uses an explicitly synthetic fixed tree with independent unknown library estimates and timestamps", async () => {
  const { source, pager } = await setup(), libraries = await source.libraries();
  assert.deepEqual(libraries, [{ libraryID: "shared", state: "synthetic", estimatedBytes: null }, { libraryID: "personal", state: "synthetic", estimatedBytes: null }]);
  const view = await pager.open({ libraryID: "shared" });
  assert.equal(view.items.length, 3); assert.equal(view.items[0].name, "01-Welcome.txt"); assert.equal(view.items[0].modifiedAt, null);
  assert.equal(view.items[0].nameKey, undefined); assert.equal(view.items[0].previewKey, undefined); assert.equal(view.total, undefined);
  assert.equal(view.nextCursor, undefined); assert.ok(Object.isFrozen(view.items[0]) && Object.isFrozen(libraries));
});
test("one page replaces the previous page, terminal next is denied and reload starts at the head", async () => {
  const { pager, source } = await setup(); const first = await pager.open({ libraryID: "shared" });
  assert.equal(first.pageNumber, 1); const second = await pager.next(); assert.equal(second.items.length, 3);
  assert.notEqual(second.items[0].name, first.items[0].name); const third = await pager.next();
  assert.deepEqual(third.items.map(x => x.name), ["Notes", "jobHash.txt"]); assert.equal(third.hasNext, false);
  assert.throws(() => pager.next(), code("denied")); assert.deepEqual((await pager.reload()).items, first.items);
  assert.deepEqual(await source.libraries(), [{ libraryID: "shared", state: "synthetic", estimatedBytes: null }, { libraryID: "personal", state: "synthetic", estimatedBytes: null }]);
});
test("search and type filters use only the current page and ordinary names", async () => {
  const { pager } = await setup(); const first = await pager.open({ libraryID: "shared" });
  assert.equal(F.filterFiles(first.items, { search: "jobHash" }).length, 0);
  assert.equal(F.filterFiles(first.items, { filter: "directory" }).length, 0);
  await pager.next(); const third = await pager.next();
  assert.deepEqual(F.filterFiles(third.items, { filter: "directory" }).map(x => x.name), ["Notes"]);
  assert.deepEqual(F.filterFiles(third.items, { search: "JOBhash" }).map(x => x.name), ["jobHash.txt"]);
  assert.throws(() => F.filterFiles(third.items, { filter: "all-directories" }), code("invalidInput"));
  assert.throws(() => F.filterFiles(third.items, { search: "x".repeat(257) }), code("invalidInput"));
});
test("empty and nested directories use relative paths without fake capacity or time", async () => {
  const { pager } = await setup(); let view = await pager.open({ libraryID: "shared", relativePath: "Empty" });
  assert.deepEqual(view.items, []); assert.equal(view.hasNext, false);
  view = await pager.open({ libraryID: "shared", relativePath: "Notes" });
  assert.equal(view.items[0].relativePath, "Notes/Readme.txt"); assert.equal(view.items[0].modifiedAt, null);
  const preview = await pager.preview("Notes/Readme.txt"); assert.match(preview.text, /合成样例/);
});
test("fixture previews preserve literal HTML-like and translation-like text with actual UTF-8 byte counts", async () => {
  const { pager } = await setup(); await pager.open({ libraryID: "shared" }); await pager.next(); await pager.next();
  const result = await pager.preview("jobHash.txt"); assert.match(result.text, /^jobHash\n<script>/);
  assert.equal(result.utf8Bytes, Buffer.byteLength(result.text)); assert.equal(pager.snapshot().phase, "ready");
  assert.equal(result.previewKey, undefined); assert.ok(Object.isFrozen(result));
});
test("previews require a supported current-page file; off-page and directory access makes no request", async () => {
  let calls = 0; const client = provider({ previewFile: async () => { calls++; throw Error("must not run"); } });
  const source = await F.createClientDirectorySource(client), pager = F.createDirectoryPager({ source });
  await pager.open({ libraryID: "literal" }); await assert.rejects(pager.preview("offpage.txt"), code("denied"));
  assert.equal(calls, 0);
  for (const [name, bytes, canPreview] of [["image.png", 10, false], ["a.txt", 65537, false], ["A.TXT", 65536, true]]) {
    const p = provider({ listFilesPage: async p => page(p, [{ ...item(name), bytes }]) });
    const s = await F.createClientDirectorySource(p), view = await s.page({ libraryID: "literal" }); assert.equal(view.items[0].canPreview, canPreview);
  }
});
test("reader cannot reach private fixture content and recovery remains read-only without creating a session", async () => {
  const reader = await setup("reader"); assert.deepEqual((await reader.source.libraries()).map(x => x.libraryID), ["shared"]);
  await assert.rejects(reader.pager.open({ libraryID: "personal" }), code("denied"));
  await assert.rejects(reader.source.preview({ libraryID: "personal", relativePath: "Private.txt" }), code("denied"));
  const recovery = await setup("recovery"); assert.equal(recovery.source.context.mode, "read_only_recovery");
  const view = await recovery.pager.open({ libraryID: "personal" }); assert.equal(view.items[0].name, "Private.txt");
  assert.ok((await recovery.pager.preview("Private.txt")).text); await assert.rejects(recovery.api.submitLabelJob({ id: "x", key: "x", value: "x" }, recovery.session), code("readOnly"));
});
test("fixture sources borrow the registered session and reject forged or ended sessions", async () => {
  const { api, session, source, pager } = await setup();
  await assert.rejects(F.createFixtureDirectorySource(api, { ...session }), code("denied"));
  await pager.open({ libraryID: "shared" }); await api.endSession(session);
  await assert.rejects(pager.next(), code("unavailable")); assert.equal(pager.snapshot().requiresReload, true);
  await assert.rejects(source.libraries(), code("unavailable"));
});
test("directory and source disposal preserve shared task and notification providers", async () => {
  const { api, session, source, pager } = await setup(), tasks = await P.createFixtureTaskSource(api, session), notifications = await N.createFixtureNotificationView(api, session, { consumerID: "borrowed-directory" });
  await pager.open({ libraryID: "shared" }); pager.dispose(); pager.dispose(); source.dispose(); source.dispose();
  assert.deepEqual(pager.snapshot().items, []); assert.equal((await tasks.overview()).userID, "fixture-owner"); assert.ok((await notifications.poll()).items.length);
  assert.equal((await api.overview(session)).role, "administrator"); notifications.dispose(); await tasks.close();
  await assert.rejects(api.overview(session), code("denied"));
});
test("expired continuation keeps a labelled old page and stops until explicit reload", async () => {
  let now = 0; const { pager } = await setup("owner", { monotonicNow: () => now });
  const first = await pager.open({ libraryID: "shared" }); now = 60000;
  await assert.rejects(pager.next(), code("expired")); const stale = pager.snapshot();
  assert.deepEqual(stale.items, first.items); assert.equal(stale.requiresReload, true); assert.equal(stale.hasNext, false);
  assert.throws(() => pager.next(), code("denied")); await assert.rejects(pager.preview(first.items[0].relativePath), code("denied"));
  assert.equal((await pager.reload()).pageNumber, 1);
});
test("fixture continuation scope, single use, fixed lifetime and explicit discard are bounded", async () => {
  let now = 0; const { source } = await setup("owner", { monotonicNow: () => now });
  const first = await source.page({ libraryID: "shared", pageSize: 1 });
  for (const p of [{ libraryID: "personal", pageSize: 1 }, { libraryID: "shared", pageSize: 2 }, { libraryID: "shared", relativePath: "Notes", pageSize: 1 }]) await assert.rejects(source.page({ ...p, cursor: first.nextCursor }), code("denied"));
  now = 30000; const second = await source.page({ libraryID: "shared", pageSize: 1, cursor: first.nextCursor });
  await assert.rejects(source.page({ libraryID: "shared", pageSize: 1, cursor: first.nextCursor }), code("denied"));
  now = 60000; await assert.rejects(source.page({ libraryID: "shared", pageSize: 1, cursor: second.nextCursor }), code("expired"));
  const cursors = []; for (let i = 0; i < 64; i++) cursors.push((await source.page({ libraryID: "shared", pageSize: 1 })).nextCursor);
  await assert.rejects(source.page({ libraryID: "shared", pageSize: 1 }), code("budgetExceeded"));
  assert.equal(source.discardCursor(cursors[0]), true); assert.equal(source.discardCursor(cursors[0]), false);
  assert.ok((await source.page({ libraryID: "shared", pageSize: 1 })).nextCursor); source.dispose();
});
test("page input rejects getters, symbols, null and unsafe paths before provider access", async () => {
  let accessed = false; const client = provider(), source = await F.createClientDirectorySource(client);
  for (const p of [null, {}, { libraryID: "literal", cursor: null }, { libraryID: "literal", pageSize: null }, { libraryID: "literal", pageSize: 101 }, { libraryID: "literal", root: "/" }, { get libraryID() { accessed = true; return "literal"; } }, { libraryID: "literal", [Symbol("x")]: 1 }]) await assert.rejects(source.page(p), code("invalidInput"));
  for (const relativePath of [null, "/a", "../a", "a//b", "a/..", "a\\b", "a:b", "a\0b", "a/".repeat(129)]) await assert.rejects(source.page({ libraryID: "literal", relativePath }), code("invalidInput"));
  assert.equal(accessed, false); assert.equal(client.calls.length, 0);
  const { api, session } = await setup(); await assert.rejects(F.createFixtureDirectorySource(api, session, { monotonicNow: null }), code("invalidInput"));
});
test("client source projects actual library metadata independently of directory availability", async () => {
  const client = provider({ listFilesPage: async () => { throw new M.ServiceError("missingVolume"); } }), source = await F.createClientDirectorySource(client);
  assert.deepEqual(await source.libraries(), [{ libraryID: "literal", state: "missing", estimatedBytes: 123 }]);
  const pager = F.createDirectoryPager({ source }); await assert.rejects(pager.open({ libraryID: "literal" }), code("missingVolume"));
  assert.equal(pager.snapshot().error, "missingVolume"); assert.equal(client.closed, false); source.dispose(); assert.equal(client.closed, false);
});
test("client projection checks exact pages, context, byte order, collisions and types, isolating only the source", async () => {
  const alterations = [
    v => ({ ...v, root: "/secret" }), v => ({ ...v, consistency: "snapshot" }), v => ({ ...v, libraryID: "other" }), v => ({ ...v, relativePath: "elsewhere" }),
    v => ({ ...v, items: [item("b.txt"), item("a.txt")] }), v => ({ ...v, items: [item("A.txt"), item("a.txt")] }),
    v => ({ ...v, items: [{ ...item("a.txt"), relativePath: "elsewhere/a.txt" }] }), v => ({ ...v, items: [{ ...item("a.txt"), bytes: Number.MAX_SAFE_INTEGER + 1 }] }),
    v => ({ ...v, items: [{ ...item("a.txt"), modifiedAt: null }] }), v => ({ ...v, items: [{ ...item("a.txt"), kind: "symlink" }] }),
    v => ({ ...v, nextCursor: token(1) }), v => ({ ...v, items: [{ ...item("a.txt"), name: "\uD800" }] })
  ];
  for (const alter of alterations) {
    const client = provider({ listFilesPage: async p => alter(page(p)) }), source = await F.createClientDirectorySource(client);
    await assert.rejects(source.page({ libraryID: "literal", pageSize: 2 }), code("invalidResponse")); assert.equal(source.closed, true); assert.equal(client.closed, false);
  }
});
test("preview response budgets, UTF-8 bytes and context are checked without returning raw diagnostics", async () => {
  for (const result of [p => ({ ...p, text: "x", utf8Bytes: 1 }), p => ({ libraryID: "other", relativePath: p.relativePath, text: "x", utf8Bytes: 1 }), p => ({ libraryID: p.libraryID, relativePath: p.relativePath, text: "🐚", utf8Bytes: 1 }), p => ({ libraryID: p.libraryID, relativePath: p.relativePath, text: "x".repeat(65537), utf8Bytes: 65537 })]) {
    const client = provider({ previewFile: async p => result(p) }), source = await F.createClientDirectorySource(client);
    await assert.rejects(source.preview({ libraryID: "literal", relativePath: "a.txt" }), code("invalidResponse")); assert.equal(client.closed, false);
  }
  const source = await F.createClientDirectorySource(provider({ previewFile: async () => { throw Error("/private/secret/password"); } }));
  await assert.rejects(source.preview({ libraryID: "literal", relativePath: "a.txt" }), e => e.code === "unavailable" && !e.message.includes("secret"));
});
test("all directory failures preserve only the current page and prevent next or previews before reload", async () => {
  for (const failure of ["staleState", "expired", "denied", "missingVolume", "budgetExceeded", "unavailable", "database"]) {
    let count = 0; const client = provider({ listFilesPage: async p => { if (++count === 2) throw new M.ServiceError(failure); return page(p, [item("a.txt")], token(count)); } });
    const source = await F.createClientDirectorySource(client), pager = F.createDirectoryPager({ source, pageSize: 1 }), first = await pager.open({ libraryID: "literal" });
    await assert.rejects(pager.next(), code(failure)); assert.deepEqual(pager.snapshot().items, first.items); assert.equal(pager.snapshot().requiresReload, true);
    assert.throws(() => pager.next(), code("denied")); await assert.rejects(pager.preview("a.txt"), code("denied")); assert.equal(count, 2);
    assert.equal((await pager.reload()).pageNumber, 1); assert.equal(count, 3);
  }
});
test("cross-page UTF-8 name ordering cannot be reused to hide duplicates or reverse order", async () => {
  let count = 0; const client = provider({ listFilesPage: async p => page(p, [item(++count === 1 ? "b.txt" : "a.txt")], count === 1 ? token(1) : null) });
  const source = await F.createClientDirectorySource(client), pager = F.createDirectoryPager({ source, pageSize: 1 }); await pager.open({ libraryID: "literal" });
  await assert.rejects(pager.next(), code("invalidResponse")); assert.equal(pager.snapshot().items[0].name, "b.txt"); assert.equal(client.closed, false);
});
test("switching directory or library during a pending page discards its result and continuation", async () => {
  for (const target of [{ libraryID: "literal", relativePath: "Notes" }, { libraryID: "other" }]) {
    const wait = deferred(); let oldParams;
    const client = provider({ listFilesPage: p => p.libraryID === "literal" && p.relativePath === "" ? (oldParams = p, wait.promise) : Promise.resolve(page(p, [item("new.txt", p.relativePath)])) });
    const source = await F.createClientDirectorySource(client), pager = F.createDirectoryPager({ source, pageSize: 1 });
    const pending = pager.open({ libraryID: "literal" }); assert.equal(pager.snapshot().phase, "loading");
    const current = await pager.open(target); wait.resolve(page(oldParams, [item("old.txt")], token(1))); await pending;
    assert.deepEqual(pager.snapshot(), current); assert.ok(client.discarded.includes(token(1))); assert.equal(client.closed, false);
  }
});
test("closing a window or disposing the identity source drops late pages and cleans returned tokens", async () => {
  for (const disposeSource of [false, true]) {
    const wait = deferred(); let params;
    const client = provider({ listFilesPage: p => (params = p, wait.promise) }), source = await F.createClientDirectorySource(client), pager = F.createDirectoryPager({ source, pageSize: 1 });
    const pending = pager.open({ libraryID: "literal" }); pager.dispose(); if (disposeSource) source.dispose();
    wait.resolve(page(params, [item("old.txt")], token(1))); await pending;
    assert.equal(pager.snapshot().phase, "closed"); assert.deepEqual(pager.snapshot().items, []); assert.ok(client.discarded.includes(token(1))); assert.equal(client.closed, false);
    if (!disposeSource) { const reopened = F.createDirectoryPager({ source, pageSize: 1 }); assert.equal(reopened.snapshot().phase, "idle"); }
  }
});
test("late page errors do not overwrite a new directory or rethrow into a closed window", async () => {
  const wait = deferred(); let count = 0;
  const client = provider({ listFilesPage: p => ++count === 1 ? wait.promise : Promise.resolve(page(p, [item("new.txt", p.relativePath)])) }), source = await F.createClientDirectorySource(client), pager = F.createDirectoryPager({ source });
  const pending = pager.open({ libraryID: "literal" }); const current = await pager.open({ libraryID: "literal", relativePath: "Notes" });
  wait.reject(new M.ServiceError("missingVolume")); assert.deepEqual(await pending, current); assert.deepEqual(pager.snapshot(), current);
});
test("preview epochs ignore both late success and failure after path, library or window change", async () => {
  for (const outcome of ["success", "failure"]) for (const target of [{ libraryID: "other" }, { libraryID: "literal", relativePath: "Notes" }, null]) {
    const wait = deferred(), client = provider({ previewFile: () => wait.promise }), source = await F.createClientDirectorySource(client), pager = F.createDirectoryPager({ source });
    await pager.open({ libraryID: "literal" }); const pending = pager.preview("a.txt"); assert.equal(pager.snapshot().phase, "previewing");
    if (target) await pager.open(target); else pager.dispose(); const expected = pager.snapshot();
    if (outcome === "success") wait.resolve({ libraryID: "literal", relativePath: "a.txt", text: "old", utf8Bytes: 3 }); else wait.reject(new M.ServiceError("denied"));
    assert.equal(await pending, null); assert.deepEqual(pager.snapshot(), expected);
  }
});
test("page and preview operations are serial within a window and preview errors disable old content", async () => {
  const wait = deferred(), client = provider({ previewFile: () => wait.promise }), source = await F.createClientDirectorySource(client), pager = F.createDirectoryPager({ source });
  await pager.open({ libraryID: "literal" }); const pending = pager.preview("a.txt");
  assert.throws(() => pager.reload(), code("busy")); assert.throws(() => pager.next(), code("busy")); await assert.rejects(pager.preview("a.txt"), code("busy"));
  wait.reject(new M.ServiceError("denied")); await assert.rejects(pending, code("denied")); assert.equal(pager.snapshot().requiresReload, true);
  assert.equal(pager.snapshot().items[0].name, "a.txt"); assert.equal((await pager.reload()).phase, "ready");
});
test("source reserves finite concurrent head-page slots and releases them when requests settle", async () => {
  const waits = [], client = provider({ listFilesPage: p => { const wait = deferred(); waits.push({ ...wait, p }); return wait.promise; } }), source = await F.createClientDirectorySource(client);
  const pending = []; for (let i = 0; i < 64; i++) pending.push(source.page({ libraryID: "literal" }));
  await assert.rejects(source.page({ libraryID: "literal" }), code("budgetExceeded")); assert.equal(waits.length, 64);
  waits.forEach(wait => wait.resolve(page(wait.p, []))); await Promise.all(pending);
  const last = source.page({ libraryID: "literal" }); waits.at(-1).resolve(page(waits.at(-1).p, [])); await last;
});
test("real typed-client timeout disconnects the borrowed source without fallback or automatic retry", async () => {
  let count = 0; const client = C.createDesktopClient({ timeoutMs: 20, transport: async request => {
    count++; if (request.method === "overview") return { apiVersion: 1, requestId: request.requestId, data: info };
    return new Promise(() => {});
  } });
  const source = await F.createClientDirectorySource(client), pager = F.createDirectoryPager({ source });
  await assert.rejects(pager.open({ libraryID: "literal" }), code("timedOut")); assert.equal(client.closed, true); assert.equal(pager.snapshot().requiresReload, true);
  await assert.rejects(pager.reload(), code("unavailable")); assert.equal(count, 2); source.dispose();
});

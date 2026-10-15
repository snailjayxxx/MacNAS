"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs"), path = require("node:path");
const M = require("../dist/model.js"), I = require("../dist/i18n.js");
const setup = async scenario => { const api = M.createFixtureAdapter({ now: () => "2026-10-15T04:30:00Z" }); return { api, session: await api.beginFixtureSession(scenario) }; };
const code = expected => error => error instanceof M.ServiceError && error.code === expected;

test("fixtures are independent, read copies cannot change authoritative roles or jobs", async () => {
  const a = await setup("owner"), b = await setup("owner");
  const info = await a.api.overview(a.session); info.role = "reader";
  const jobs = await a.api.listJobs(a.session); jobs[0].state = "completed";
  await a.api.cancelJob("demo-hash", a.session);
  assert.equal((await a.api.overview(a.session)).role, "administrator");
  assert.equal((await b.api.listJobs(b.session))[0].state, "running");
});
test("reader has only owned jobs and cannot cancel another user or open admin route", async () => {
  const { api, session } = await setup("reader");
  assert.deepEqual((await api.listJobs(session)).map(j => j.id), ["family-job"]);
  await assert.rejects(api.cancelJob("demo-hash", session), code("denied"));
  await assert.rejects(api.authorizeApp("settings", session), code("denied"));
  await assert.rejects(api.submitLabelJob({ id: "r", key: "r", value: "no" }, session), code("denied"));
  assert.equal((await api.cancelJob("family-job", session)).state, "cancelled");
  assert.equal(await api.authorizeApp("preferences", session), true);
});
test("expired fixture sessions, forged sessions and cross-instance sessions are rejected", async () => {
  const { api, session } = await setup("owner");
  const other = M.createFixtureAdapter();
  await assert.rejects(other.overview(session), code("denied"));
  await assert.rejects(api.overview({ ...session }), code("denied"));
  await api.endSession(session); await assert.rejects(api.listJobs(session), code("denied"));
});
test("read-only mode still reads jobs but refuses cancel, submit, poll and ack", async () => {
  const { api, session } = await setup("recovery");
  assert.equal((await api.overview(session)).mode, "read_only_recovery");
  assert.equal((await api.listJobs(session)).length, 5);
  for (const operation of [() => api.cancelJob("demo-hash", session), () => api.submitLabelJob({ id: "x", key: "x", value: "x" }, session), () => api.pollEvents("c", session), () => api.acknowledgeEvents("c", 1, session)]) await assert.rejects(operation, code("readOnly"));
  assert.equal((await api.listJobs(session))[0].state, "running");
});
test("cancel is idempotent and terminal outcomes are preserved", async () => {
  const { api, session } = await setup("owner");
  const first = await api.cancelJob("demo-hash", session);
  assert.deepEqual(await api.cancelJob("demo-hash", session), first);
  assert.equal((await api.cancelJob("demo-complete", session)).state, "completed");
  const events = await api.pollEvents("c", session);
  assert.equal(events.filter(e => e.job_id === "demo-hash").length, 1);
});
test("submission binds immutable data and unique keys without overwriting another task", async () => {
  const { api, session } = await setup("owner");
  const request = { id: "x", key: "k", value: "a <script>alert(1)</script>" };
  const first = await api.submitLabelJob(request, session);
  assert.equal(first.title, request.value);
  assert.deepEqual(await api.submitLabelJob(request, session), first);
  await assert.rejects(api.submitLabelJob({ ...request, value: "different" }, session), code("collision"));
  await assert.rejects(api.submitLabelJob({ ...request, id: "y", key: "k2", value: " " }, session), code("invalidInput"));
});
test("events repeat before acknowledgement; unknown and undelivered acknowledgements fail", async () => {
  const { api, session } = await setup("owner");
  const first = await api.pollEvents("desktop", session, 1);
  assert.equal(first.length, 1);
  assert.deepEqual(await api.pollEvents("desktop", session, 1), first);
  await assert.rejects(api.acknowledgeEvents("desktop", 4, session), code("denied"));
  await api.acknowledgeEvents("desktop", first[0].sequence, session);
  await api.acknowledgeEvents("desktop", first[0].sequence, session);
  assert.ok((await api.pollEvents("desktop", session)).every(e => e.sequence > first[0].sequence));
  await assert.rejects(api.acknowledgeEvents("desktop", 0, session), code("denied"));
});
test("consumer IDs remain audience-bound across session changes", async () => {
  const { api, session } = await setup("owner");
  const reader = await api.beginFixtureSession("reader");
  await api.pollEvents("private", session);
  await assert.rejects(api.pollEvents("private", reader), code("denied"));
  await assert.rejects(api.acknowledgeEvents("private", 1, reader), code("denied"));
  assert.deepEqual((await api.pollEvents("reader", reader)).map(e => e.job_id), ["family-job"]);
});
test("event replay merges by sequence without reviving previously known duplicates", () => {
  const event = { sequence: 8, job_id: "x", revision: 2, type: "cancelled", state: "cancelled" };
  const original = M.mergeEvents([], [event]);
  assert.deepEqual(M.mergeEvents(original, [event, event]), original);
  assert.equal(original.length, 1);
  assert.throws(() => M.mergeEvents(original, [{ ...event, job_id: "other" }]), code("invalidResponse"));
  assert.throws(() => M.mergeEvents([], [{ ...event, sequence: Number.MAX_SAFE_INTEGER + 1 }]), code("invalidResponse"));
  assert.throws(() => M.mergeEvents([], [{ ...event, state: "active" }]), code("invalidResponse"));
  assert.throws(() => M.mergeEvents([], [{ ...event, revision: "2" }]), code("invalidResponse"));
});
test("shared file navigation checks every direct resource request", async () => {
  const { api, session } = await setup("reader");
  assert.deepEqual((await api.listFiles("", session)).map(f => f.id), ["shared"]);
  assert.equal((await api.listFiles("shared", session)).length, 2);
  await assert.rejects(api.listFiles("personal", session), code("denied"));
  await assert.rejects(api.previewFile("note", session), code("denied"));
  await assert.rejects(api.listFiles("../", session), code("denied"));
});
test("geometry handles offscreen, zero coordinates, NaN and mobile bounds", () => {
  for (const dimensions of [{ width: 1440, height: 830 }, { width: 390, height: 726 }, { width: 320, height: 500 }]) {
    for (const candidate of [{ x: 0, y: 0, w: 10000, h: 10000 }, { x: -500, y: -5 }, { x: NaN, y: Infinity, w: NaN, h: -3 }]) {
      const g = M.geometry(candidate, dimensions);
      assert.ok(g.x >= 8 && g.y >= 8 && g.x + g.w <= dimensions.width - 8 && g.y + g.h <= dimensions.height - 8);
    }
  }
  assert.equal(M.geometry({ x: 0, y: 0 }).x, 8);
  assert.equal(M.geometry({ x: 0, y: 0 }).y, 8);
});
test("preferences recover from corruption and persist only UI fields", () => {
  assert.equal(M.readPreferences({ getItem: () => "broken" }).locale, "zh-CN");
  assert.equal(M.readPreferences({ getItem: () => { throw Error("blocked"); } }).theme, "night");
  const memory = { value: "", getItem() { return this.value; }, setItem(k, v) { this.value = v; } };
  M.savePreferences(memory, { version: 1, locale: "ja-JP", theme: "dawn", session: "secret", jobs: [{ private: true }], windows: { overview: { x: 20, y: 30, w: 600, h: 500 }, adminEscape: {} } });
  const parsed = JSON.parse(memory.value);
  assert.deepEqual(Object.keys(parsed).sort(), ["locale", "theme", "version", "windows"]);
  assert.deepEqual(Object.keys(parsed.windows), ["overview"]);
  assert.equal(M.readPreferences(memory).locale, "ja-JP");
  assert.equal(M.savePreferences({ setItem: () => { throw Error("blocked"); } }, parsed), false);
});
test("languages have complete interpolation parity and no implicit missing key fallback", () => {
  const zh = I.dictionaries["zh-CN"], ja = I.dictionaries["ja-JP"];
  assert.ok(Object.keys(zh).length >= 180);
  assert.deepEqual(Object.keys(zh).sort(), Object.keys(ja).sort());
  for (const key of Object.keys(zh)) {
    assert.equal(typeof ja[key], "string");
    assert.ok(zh[key] && ja[key]);
    assert.deepEqual([...zh[key].matchAll(/\{(\w+)\}/g)].map(m => m[1]).sort(), [...ja[key].matchAll(/\{(\w+)\}/g)].map(m => m[1]).sort(), key);
  }
  assert.equal(I.t("ja-JP", "attempts", { count: 1, max: 3 }), "試行 1 / 3");
  assert.throws(() => I.t("zh-CN", "missing"));
  const ui = fs.readFileSync(path.join(__dirname, "../dist/desktop.js"), "utf8");
  for (const [, key] of ui.matchAll(/\bt\("([A-Za-z_]+)"/g)) assert.ok(key in zh, key);
});
test("bridge envelopes bind protocol/request IDs and never fall back to fixture data", async () => {
  const missing = M.createBridgeAdapter();
  await assert.rejects(missing.request("overview"), code("unavailable"));
  const bridge = M.createBridgeAdapter(async request => ({ apiVersion: 1, requestId: request.requestId, data: { source: "host", received: request.method } }));
  assert.deepEqual(await bridge.request("overview"), { source: "host", received: "overview" });
  await assert.rejects(bridge.request("executeSQL", { sql: "DROP DATABASE" }), code("invalidInput"));
  const mismatch = M.createBridgeAdapter(async () => ({ apiVersion: 2, requestId: "wrong", data: {} }));
  await assert.rejects(mismatch.request("overview"), code("invalidResponse"));
  const denial = M.createBridgeAdapter(async r => ({ apiVersion: 1, requestId: r.requestId, error: { code: "denied" } }));
  await assert.rejects(denial.request("cancelJob", { id: "x" }), code("denied"));
});
test("static entrypoint has no external assets, inline scripts or network connection policy", () => {
  const root = path.join(__dirname, "../dist"), html = fs.readFileSync(path.join(root, "index.html"), "utf8");
  assert.match(html, /connect-src 'none'/);
  assert.doesNotMatch(html, /<(script|link|img)[^>]+(?:src|href)=["']https?:/i);
  assert.doesNotMatch(html, /<script(?:\s[^>]*)?>\s*[^<\s]/i);
  for (const file of ["model.js", "i18n.js", "desktop.js", "desktop.css", "icon.svg"]) assert.ok(fs.existsSync(path.join(root, file)));
});

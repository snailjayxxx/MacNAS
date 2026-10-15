(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.MacNASModel = Object.freeze(api);
})(globalThis, function () {
  "use strict";
  const clone = (value) => JSON.parse(JSON.stringify(value));
  const states = Object.freeze(["queued", "running", "waiting_for_volume", "paused", "failed", "completed", "cancelled"]);
  const apps = Object.freeze(["overview", "files", "storage", "apps", "tasks", "settings", "preferences"]);
  class ServiceError extends Error {
    constructor(code) { super(code); this.name = "ServiceError"; this.code = code; }
  }
  function check(value, code = "invalidInput") { if (!value) throw new ServiceError(code); }
  const initialJobs = [
    { id: "demo-hash", idempotency_key: "demo-hash", kind: "fixtureHash", owner_user: "fixture-owner", app_id: null, titleKey: "jobHash", state: "running", attempts: 1, max_attempts: 3, checkpoint: { step: "prepared" }, revision: 3, effects: 0, updated: "2026-10-15T04:20:00Z", last_error: null },
    { id: "demo-retry", idempotency_key: "demo-retry", kind: "label", owner_user: "fixture-owner", app_id: null, titleKey: "jobLabels", state: "queued", attempts: 1, max_attempts: 3, checkpoint: { step: "prepared" }, revision: 4, effects: 0, updated: "2026-10-15T04:18:00Z", last_error: "timedOut" },
    { id: "demo-volume", idempotency_key: "demo-volume", kind: "fixtureHash", owner_user: "fixture-owner", app_id: null, titleKey: "jobVolume", state: "waiting_for_volume", attempts: 0, max_attempts: 3, checkpoint: {}, revision: 3, effects: 0, updated: "2026-10-15T04:16:00Z", last_error: "missingVolume" },
    { id: "demo-failed", idempotency_key: "demo-failed", kind: "fixtureHash", owner_user: "fixture-owner", app_id: null, titleKey: "jobVerify", state: "failed", attempts: 3, max_attempts: 3, checkpoint: { step: "prepared" }, revision: 8, effects: 0, updated: "2026-10-15T04:14:00Z", last_error: "timedOut" },
    { id: "demo-complete", idempotency_key: "demo-complete", kind: "label", owner_user: "fixture-owner", app_id: null, titleKey: "jobComplete", state: "completed", attempts: 1, max_attempts: 3, checkpoint: { step: "completed" }, revision: 4, effects: 1, updated: "2026-10-15T04:10:00Z", last_error: null },
    { id: "family-job", idempotency_key: "family-job", kind: "fixtureHash", owner_user: "fixture-family", app_id: null, titleKey: "jobFamily", state: "waiting_for_volume", attempts: 0, max_attempts: 3, checkpoint: {}, revision: 2, effects: 0, updated: "2026-10-15T04:12:00Z", last_error: "missingVolume" }
  ];
  const initialEvents = [
    { sequence: 1, job_id: "demo-complete", revision: 4, owner_user: "fixture-owner", type: "completed", state: "completed" },
    { sequence: 2, job_id: "family-job", revision: 2, owner_user: "fixture-family", type: "deferred", state: "waiting_for_volume" },
    { sequence: 3, job_id: "demo-failed", revision: 8, owner_user: "fixture-owner", type: "deferred", state: "failed" },
    { sequence: 4, job_id: "demo-volume", revision: 3, owner_user: "fixture-owner", type: "deferred", state: "waiting_for_volume" }
  ];
  const files = [
    { id: "shared", parent: "", nameKey: "sharedLibrary", kind: "folder", audience: "all", size: "", modified: "2026-10-14" },
    { id: "personal", parent: "", nameKey: "personalLibrary", kind: "folder", audience: "fixture-owner", size: "", modified: "2026-10-15" },
    { id: "welcome", parent: "shared", nameKey: "welcomeFile", kind: "text", audience: "all", size: "2 KB", modified: "2026-10-15", previewKey: "welcomePreview" },
    { id: "guide", parent: "shared", nameKey: "guideFile", kind: "text", audience: "all", size: "8 KB", modified: "2026-10-14", previewKey: "guidePreview" },
    { id: "travel", parent: "personal", nameKey: "tripFolder", kind: "folder", audience: "fixture-owner", size: "", modified: "2026-10-13" },
    { id: "note", parent: "personal", nameKey: "noteFile", kind: "text", audience: "fixture-owner", size: "4 KB", modified: "2026-10-15", previewKey: "notePreview" },
    { id: "list", parent: "travel", nameKey: "tripFile", kind: "text", audience: "fixture-owner", size: "1 KB", modified: "2026-10-13", previewKey: "tripPreview" }
  ];
  function createFixtureAdapter({ now = () => new Date().toISOString() } = {}) {
    const jobs = clone(initialJobs), events = clone(initialEvents);
    const sessions = new Map(), consumers = new Map(), submissions = new Map();
    let nextSequence = 5, serial = 0;
    function caller(session) {
      const value = sessions.get(session);
      check(value, "denied");
      return value;
    }
    function write(session) { const user = caller(session); check(user.mode === "synthetic_development", "readOnly"); return user; }
    function ownJob(id, user) { const job = jobs.find(j => j.id === id && j.owner_user === user.id && j.app_id === null); check(job, "denied"); return job; }
    function emit(job, type) {
      events.push({ sequence: nextSequence++, job_id: job.id, revision: job.revision, owner_user: job.owner_user, type, state: job.state });
    }
    const service = {
      source: "fixture",
      async beginFixtureSession(scenario = "owner") {
        check(["owner", "reader", "recovery"].includes(scenario));
        const session = Object.freeze({ fixture: true, serial: ++serial });
        sessions.set(session, { id: scenario === "reader" ? "fixture-family" : "fixture-owner", role: scenario === "reader" ? "reader" : "administrator", mode: scenario === "recovery" ? "read_only_recovery" : "synthetic_development" });
        return session;
      },
      async endSession(session) { sessions.delete(session); },
      async overview(session) {
        const user = caller(session), visible = jobs.filter(j => j.owner_user === user.id && j.app_id === null);
        return clone({ apiVersion: 1, source: "fixture", userID: user.id, role: user.role, mode: user.mode, languages: ["zh-CN", "ja-JP"], databaseSchema: 3,
          active: visible.filter(j => ["queued", "running", "waiting_for_volume"].includes(j.state)).length,
          completed: visible.filter(j => j.state === "completed").length, logicalReferenceBytes: 35000000000000, physicalPool: "unbound" });
      },
      async authorizeApp(id, session) { const user = caller(session); check(apps.includes(id), "notFound"); check(id !== "settings" || user.role === "administrator", "denied"); return true; },
      async listJobs(session) { const user = caller(session); return clone(jobs.filter(j => j.owner_user === user.id && j.app_id === null)); },
      async submitLabelJob({ id, key, value }, session) {
        const user = write(session); check(user.role === "administrator", "denied");
        check(typeof id === "string" && id.length > 0 && id.length <= 128 && typeof key === "string" && key.length > 0 && key.length <= 128);
        check(typeof value === "string" && value.trim().length > 0 && value.length <= 80);
        const previous = submissions.get(key);
        if (previous) { check(previous.user === user.id && previous.value === value, "collision"); return clone(ownJob(previous.id, user)); }
        check(!jobs.some(j => j.id === id || j.idempotency_key === key), "collision");
        const job = { id, idempotency_key: key, kind: "label", owner_user: user.id, app_id: null, title: value, titleKey: "jobLabels", state: "queued", attempts: 0, max_attempts: 3, checkpoint: {}, revision: 1, effects: 0, updated: now(), last_error: null };
        jobs.unshift(job); submissions.set(key, { user: user.id, value, id }); emit(job, "queued");
        return clone(job);
      },
      async cancelJob(id, session) {
        const user = write(session), job = ownJob(id, user);
        if (!["failed", "completed", "cancelled"].includes(job.state)) {
          job.state = "cancelled"; job.revision++; job.updated = now(); emit(job, "cancelled");
        }
        return clone(job);
      },
      async pollEvents(consumerID, session, limit = 50) {
        const user = write(session); check(typeof consumerID === "string" && consumerID.length > 0 && consumerID.length <= 128 && Number.isInteger(limit) && limit >= 1 && limit <= 100);
        let consumer = consumers.get(consumerID);
        if (!consumer) { consumer = { user: user.id, ack: 0, delivered: 0, receipts: new Set() }; consumers.set(consumerID, consumer); }
        check(consumer.user === user.id, "denied");
        const page = events.filter(e => e.owner_user === user.id && e.sequence > consumer.ack).slice(0, limit);
        consumer.delivered = Math.max(consumer.delivered, ...page.map(e => e.sequence));
        return clone(page.map(({ owner_user, ...event }) => event));
      },
      async acknowledgeEvents(consumerID, through, session) {
        const user = write(session), consumer = consumers.get(consumerID);
        check(consumer && consumer.user === user.id, "denied");
        check(Number.isSafeInteger(through) && through >= consumer.ack && through <= consumer.delivered, "denied");
        check(through === consumer.ack || events.some(e => e.sequence === through && e.owner_user === user.id), "denied");
        for (const event of events) if (event.owner_user === user.id && event.sequence > consumer.ack && event.sequence <= through) consumer.receipts.add(event.sequence);
        consumer.ack = through;
      },
      async listFiles(parent, session) {
        const user = caller(session); check(typeof parent === "string" && (parent === "" || files.some(f => f.id === parent && f.kind === "folder" && (f.audience === "all" || f.audience === user.id))), "denied");
        return clone(files.filter(f => f.parent === parent && (f.audience === "all" || f.audience === user.id)));
      },
      async previewFile(id, session) {
        const user = caller(session), file = files.find(f => f.id === id && f.kind === "text" && (f.audience === "all" || f.audience === user.id));
        check(file, "denied"); return clone(file);
      }
    };
    return Object.freeze(service);
  }
  function mergeEvents(previous, incoming) {
    const bySequence = new Map(previous.map(e => [e.sequence, clone(e)]));
    for (const event of incoming) {
      check(Number.isSafeInteger(event.sequence) && event.sequence > 0 && typeof event.job_id === "string" && Number.isSafeInteger(event.revision) && event.revision>=1 && ["queued","claimed","checkpoint","completed","deferred","failed","cancelled"].includes(event.type) && states.includes(event.state), "invalidResponse");
      const existing = bySequence.get(event.sequence);
      if (existing) check(existing.job_id === event.job_id && existing.revision === event.revision && existing.state === event.state && existing.type === event.type, "invalidResponse");
      else bySequence.set(event.sequence, clone(event));
    }
    return [...bySequence.values()].sort((a, b) => b.sequence - a.sequence);
  }
  function geometry(value = {}, area = { width: 1280, height: 760 }) {
    const safe = n => Number.isFinite(n) ? n : 0;
    const width = Math.max(280, safe(area.width)), height = Math.max(300, safe(area.height));
    const w = Math.min(width - 16, Math.max(Math.min(540, width - 16), safe(value.w) || 1060));
    const h = Math.min(height - 16, Math.max(Math.min(390, height - 16), safe(value.h) || 680));
    return { x: Math.max(8, Math.min(width - w - 8, Number.isFinite(value.x) ? value.x : (width - w) / 2)), y: Math.max(8, Math.min(height - h - 8, Number.isFinite(value.y) ? value.y : 34)), w, h };
  }
  function readPreferences(storage) {
    const fallback = { version: 1, locale: "zh-CN", theme: "night", windows: {} };
    try {
      const parsed = JSON.parse(storage.getItem("macnas.desktop.preferences.v1"));
      if (parsed?.version !== 1 || !["zh-CN", "ja-JP"].includes(parsed.locale) || !["night", "dawn"].includes(parsed.theme)) return fallback;
      const windows = {};
      for (const [id, value] of Object.entries(parsed.windows || {})) if (apps.includes(id) && value && typeof value === "object") windows[id] = { x: value.x, y: value.y, w: value.w, h: value.h };
      return { version: 1, locale: parsed.locale, theme: parsed.theme, windows };
    } catch { return fallback; }
  }
  function savePreferences(storage, value) {
    try {
      const clean = readPreferences({ getItem: () => JSON.stringify(value) });
      storage.setItem("macnas.desktop.preferences.v1", JSON.stringify(clean)); return true;
    } catch { return false; }
  }
  function checkedBridgeJSON(value, maximumBytes, maximumNodes, code) {
    let nodes = 0, measured = 0;
    const seen = new Set(), encoder = new TextEncoder();
    const budget = code === "invalidInput" ? "budgetExceeded" : code;
    function textSize(text) {
      check(text.length <= maximumBytes, budget);
      for (let i = 0; i < text.length; i++) {
        const unit = text.charCodeAt(i);
        if (unit >= 0xD800 && unit <= 0xDBFF) {
          const next = text.charCodeAt(++i); check(next >= 0xDC00 && next <= 0xDFFF, code);
        } else check(!(unit >= 0xDC00 && unit <= 0xDFFF), code);
      }
      measured += encoder.encode(text).length; check(measured <= maximumBytes, budget);
    }
    function visit(item, depth) {
      check(depth <= 16 && ++nodes <= maximumNodes, budget);
      if (item === null || typeof item === "boolean") { measured += 5; return; }
      if (typeof item === "string") { textSize(item); return; }
      if (typeof item === "number") { check(Number.isFinite(item) && (!Number.isInteger(item) || Number.isSafeInteger(item)), code); measured += 24; return; }
      check(item && typeof item === "object" && !seen.has(item), code);
      const array = Array.isArray(item);
      check(array || Object.getPrototypeOf(item) === Object.prototype, code);
      check(!array || item.length <= maximumNodes, budget);
      seen.add(item);
      const descriptors = Object.getOwnPropertyDescriptors(item), keys = Reflect.ownKeys(descriptors);
      if (array) check(keys.length === item.length + 1, code);
      for (const key of keys) {
        check(typeof key === "string", code);
        const descriptor = descriptors[key];
        if (array && key === "length") continue;
        check(descriptor.enumerable && Object.hasOwn(descriptor, "value"), code);
        if (array) check(/^(0|[1-9][0-9]*)$/.test(key) && Number(key) < item.length, code);
        textSize(key); visit(descriptor.value, depth + 1);
      }
      seen.delete(item);
    }
    visit(value, 0);
    let encoded;
    try { encoded = JSON.stringify(value); } catch { throw new ServiceError(code); }
    check(typeof encoded === "string" && encoder.encode(encoded).length <= maximumBytes, budget);
    return JSON.parse(encoded);
  }
  function createBridgeAdapter(transport) {
    const allowed = new Set(["overview", "authorizeApp", "listJobs", "submitLabelJob", "cancelJob", "pollEvents", "acknowledgeEvents", "listLibraries", "listFiles", "previewFile"]);
    const errors = new Set(["invalidInput","invalidResponse","unsupported","denied","readOnly","unavailable","budgetExceeded","replay","collision","missingVolume","unsafePath","unsafeFile","integrity","database","busy","expired","staleState","interrupted","timedOut","cancelled","pluginFailed"]);
    let serial = 0;
    return Object.freeze({
      source: "bridge",
      async request(method, params = {}) {
        check(allowed.has(method) && params && Object.getPrototypeOf(params) === Object.prototype, "invalidInput");
        check(typeof transport === "function", "unavailable");
        const requestId = "desktop-" + (++serial);
        const message = checkedBridgeJSON({ apiVersion: 1, requestId, method, params }, 65536, 4096, "invalidInput");
        let raw;
        try { raw = await transport(message); } catch { throw new ServiceError("unavailable"); }
        const response = checkedBridgeJSON(raw, 1048576, 65536, "invalidResponse");
        check(response && !Array.isArray(response) && response.apiVersion === 1 && response.requestId === requestId, "invalidResponse");
        const keys = Object.keys(response), hasData = Object.hasOwn(response, "data"), hasError = Object.hasOwn(response, "error");
        check(hasData !== hasError && keys.length === 3 && keys.every(key => ["apiVersion","requestId","data","error"].includes(key)), "invalidResponse");
        if (hasError) {
          check(response.error && !Array.isArray(response.error) && Object.keys(response.error).length === 1 && errors.has(response.error.code), "invalidResponse");
          throw new ServiceError(response.error.code);
        }
        return response.data;
      }
    });
  }
  return { states, apps, ServiceError, createFixtureAdapter, createBridgeAdapter, mergeEvents, geometry, readPreferences, savePreferences };
});

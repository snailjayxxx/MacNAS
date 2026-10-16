(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory(require("./model.js"));
  else root.MacNASTaskPages = Object.freeze(factory(root.MacNASModel));
})(globalThis, function (M) {
  "use strict";
  const sources = new WeakSet(), encoder = new TextEncoder();
  const check = (condition, code = "invalidResponse") => { if (!condition) throw new M.ServiceError(code); };
  const errors = new Set(["invalidInput","invalidResponse","unsupported","denied","readOnly","unavailable","budgetExceeded","replay","collision","missingVolume","unsafePath","unsafeFile","integrity","database","busy","expired","staleState","interrupted","timedOut","cancelled","pluginFailed","invalidSchema"]);
  const freeze = value => { if (value && typeof value === "object") { for (const item of Object.values(value)) freeze(item); Object.freeze(value); } return value; };
  const text = (value, maximum = 128, empty = false) => {
    check(typeof value === "string" && (empty || value.length > 0) && value.length <= maximum && !value.includes("\0"));
    for (let i = 0; i < value.length; i++) {
      const unit = value.charCodeAt(i);
      if (unit >= 0xD800 && unit <= 0xDBFF) { const next = value.charCodeAt(++i); check(next >= 0xDC00 && next <= 0xDFFF); }
      else check(!(unit >= 0xDC00 && unit <= 0xDFFF));
    }
    check(encoder.encode(value).length <= maximum); return value;
  };
  const integer = (value, min = 0, max = Number.MAX_SAFE_INTEGER) => { check(Number.isSafeInteger(value) && value >= min && value <= max); return value; };
  const errorCode = error => error instanceof M.ServiceError && errors.has(error.code) ? error.code : "unavailable";
  async function call(operation) { try { return await operation(); } catch (error) { throw new M.ServiceError(errorCode(error)); } }
  function context(info, kind) {
    check(info && info.source === kind && info.apiVersion === 1 && (kind === "fixture" ? info.databaseSchema === 3 : [3,4,5,6].includes(info.databaseSchema)) && info.physicalPool === "unbound");
    text(info.userID); check(["administrator","reader"].includes(info.role) && ["synthetic_development","read_only_recovery","rolled_back_recovery"].includes(info.mode));
    return freeze({ source: kind, userID: info.userID, role: info.role, mode: info.mode });
  }
  function task(raw, who) {
    check(raw && typeof raw === "object"); text(raw.id);
    check(raw.owner_user === who.userID && (raw.app_id === undefined || raw.app_id === null));
    check(["label","fixtureHash"].includes(raw.kind) && M.states.includes(raw.state));
    const maxAttempts = integer(raw.max_attempts, 1, 8), attempts = integer(raw.attempts, 0, maxAttempts);
    integer(raw.revision, 1); integer(raw.effects, 0, 1);
    const step = raw.checkpoint?.step; check(step === undefined || ["prepared","completed"].includes(step));
    check(raw.state === "completed" ? step === "completed" && raw.effects === 1 && attempts >= 1 : step !== "completed" && raw.effects === 0);
    if (raw.state === "running") check(attempts >= 1);
    const lastError = raw.last_error ?? null; check(lastError === null || errors.has(lastError));
    let name;
    if (Object.hasOwn(raw, "title")) name = { kind: "text", value: text(raw.title, 1024, true) };
    else {
      const keys = who.source === "fixture" ? ["jobHash","jobLabels","jobVolume","jobVerify","jobComplete","jobFamily"] : ["jobHash","jobLabels"];
      check(keys.includes(raw.titleKey)); name = { kind: "key", value: raw.titleKey };
    }
    return freeze({ id: raw.id, name, kind: raw.kind, state: raw.state, attempts, maxAttempts, revision: raw.revision,
      steps: step === "completed" ? 2 : step === "prepared" ? 1 : 0, lastError });
  }
  async function makeSource(kind, operations) {
    let closed = false, binding;
    const cursors = new Set();
    function alive() { check(!closed && !operations.isClosed?.(), "unavailable"); }
    async function overview() {
      alive(); const info = await call(operations.overview); alive(); const who = context(info, kind);
      if (binding && !["userID","role","mode"].every(key => who[key] === binding[key])) { await close(); throw new M.ServiceError("denied"); }
      else binding = who;
      return freeze({ ...binding, active: integer(info.active), completed: integer(info.completed), taskTimestampsAvailable: false });
    }
    function discard(cursor) {
      if (cursor === null || cursor === undefined || !cursors.has(cursor)) return false;
      // A page already in flight is cleaned up after its result settles.
      try { const result = operations.discard(cursor); cursors.delete(cursor); return result; } catch { return false; }
    }
    async function close() { if (closed) return; closed = true; cursors.clear(); await call(operations.close); }
    try { await overview(); } catch (error) { await close(); throw new M.ServiceError(errorCode(error)); }
    const source = Object.freeze({
      get closed() { return closed || !!operations.isClosed?.(); }, context: binding, overview, close, discardCursor: discard,
      async page(params = {}) {
        alive(); const p = M.pageParameters(params);
        if (p.cursor !== undefined) check(cursors.has(p.cursor), "denied");
        const raw = await call(() => operations.page(p.cursor === undefined ? { pageSize: p.pageSize } : p));
        if (closed || operations.isClosed?.()) { if (raw?.nextCursor) { try { operations.discard(raw.nextCursor); } catch {} } throw new M.ServiceError("cancelled"); }
        try {
          check(raw && Object.keys(raw).length === 6 && ["pageVersion","order","consistency","pageSize","items","nextCursor"].every(key => Object.hasOwn(raw, key)));
          check(raw.pageVersion === 1 && raw.order === "id-utf8" && raw.consistency === "live" && raw.pageSize === p.pageSize);
          check(Array.isArray(raw.items) && raw.items.length <= p.pageSize);
          const tasks = raw.items.map(value => task(value, binding));
          for (let i = 1; i < tasks.length; i++) check(M.compareTaskIDs(tasks[i-1].id, tasks[i].id) < 0);
          if (raw.nextCursor !== null) {
            M.pageParameters({ cursor: raw.nextCursor }); check(tasks.length === p.pageSize && raw.nextCursor !== p.cursor && !cursors.has(raw.nextCursor));
            check(cursors.size - (p.cursor === undefined ? 0 : 1) < 128, "budgetExceeded");
          }
          if (p.cursor !== undefined) cursors.delete(p.cursor);
          if (raw.nextCursor !== null) cursors.add(raw.nextCursor);
          return freeze({ viewVersion: 1, pageSize: p.pageSize, tasks, nextCursor: raw.nextCursor });
        } catch (error) { await close(); throw new M.ServiceError(error instanceof M.ServiceError && error.code === "budgetExceeded" ? "budgetExceeded" : "invalidResponse"); }
      },
      async cancelJob(id) {
        alive(); text(id); check(binding.mode === "synthetic_development", "readOnly");
        const raw = await call(() => operations.cancel(id)); alive();
        try { const result = task(raw, binding); check(result.id === id && ["completed","failed","cancelled"].includes(result.state)); return result; }
        catch { await close(); throw new M.ServiceError("invalidResponse"); }
      },
      async submitLabelJob(intent) {
        alive(); check(binding.mode === "synthetic_development", "readOnly"); check(binding.role === "administrator", "denied");
        const raw = await call(() => operations.submit(intent)); alive();
        try { return task(raw, binding); } catch { await close(); throw new M.ServiceError("invalidResponse"); }
      }
    });
    sources.add(source); return source;
  }
  async function createFixtureTaskSource(api, session) {
    check(api?.source === "fixture" && ["overview","listJobsPage","cancelJob","submitLabelJob","discardJobPage","endSession"].every(key => typeof api[key] === "function"), "unavailable");
    return makeSource("fixture", { overview: () => api.overview(session), page: p => api.listJobsPage(p, session),
      cancel: id => api.cancelJob(id, session), submit: p => api.submitLabelJob(p, session),
      discard: cursor => { void api.discardJobPage(cursor, session).catch(() => {}); return true; }, close: () => api.endSession(session) });
  }
  async function createClientTaskSource(client) {
    check(client?.source === "fixture-host-client" && !client.closed && ["overview","listJobsPage","cancelJob","submitLabelJob","discardJobPage","close"].every(key => typeof client[key] === "function"), "unavailable");
    return makeSource("fixture-host", { overview: () => client.overview(), page: p => client.listJobsPage(p),
      cancel: id => client.cancelJob(id), submit: p => client.submitLabelJob(p), discard: cursor => client.discardJobPage(cursor), close: () => client.close(), isClosed: () => client.closed });
  }
  function createTaskPager({ source, pageSize = 50 } = {}) {
    check(sources.has(source), "invalidInput"); M.pageParameters({ pageSize });
    let cursor = null, generation = 0;
    let view = freeze({ phase: "idle", items: [], pageNumber: 0, hasNext: false, error: null, requiresReload: false });
    const update = values => { view = freeze({ ...view, ...values }); return view; };
    function ready() { check(view.phase !== "closed", "unavailable"); check(!["loading","mutating"].includes(view.phase), "busy"); }
    async function load(reset) {
      ready();
      if (!reset) check(view.phase === "ready" && cursor !== null && !view.requiresReload && view.pageNumber < 4096, "denied");
      const epoch = generation, previous = cursor; let receivedCursor;
      if (reset) { source.discardCursor(previous); cursor = null; update({ items: [], pageNumber: 0, hasNext: false }); }
      update({ phase: "loading", error: null, requiresReload: false });
      try {
        const page = await source.page(reset ? { pageSize } : { pageSize, cursor: previous });
        receivedCursor = page.nextCursor;
        if (epoch !== generation) { source.discardCursor(page.nextCursor); source.discardCursor(previous); return view; }
        if (!reset && page.tasks.length && view.items.length) check(M.compareTaskIDs(view.items.at(-1).id, page.tasks[0].id) < 0);
        cursor = page.nextCursor;
        return update({ phase: "ready", items: page.tasks, pageNumber: reset ? 1 : view.pageNumber + 1, hasNext: cursor !== null });
      } catch (error) {
        source.discardCursor(receivedCursor);
        source.discardCursor(previous);
        if (epoch !== generation) return view;
        cursor = null; update({ phase: "error", hasNext: false, error: errorCode(error), requiresReload: true });
        throw new M.ServiceError(view.error);
      }
    }
    return Object.freeze({
      snapshot: () => view, reload: () => load(true), next: () => load(false),
      dispose() { if (view.phase === "closed") return; generation++; source.discardCursor(cursor); cursor = null; update({ phase: "closed", items: [], pageNumber: 0, hasNext: false, error: null, requiresReload: false }); },
      async cancelJob(id) {
        ready(); check(view.phase === "ready" && view.items.some(item => item.id === id), "denied");
        const epoch = generation; update({ phase: "mutating", error: null });
        try {
          const result = await source.cancelJob(id);
          if (epoch !== generation) return view;
          return update({ phase: "ready", items: view.items.map(item => item.id === id ? result : item) });
        } catch (error) {
          if (epoch !== generation) return view;
          source.discardCursor(cursor); cursor = null;
          update({ phase: "error", error: errorCode(error), requiresReload: true, hasNext: false }); throw new M.ServiceError(view.error);
        }
      }
    });
  }
  function taskName(task, translate) { return task.name.kind === "text" ? task.name.value : translate(task.name.value); }
  function filterTasks(items, { filter = "all", search = "" } = {}, translate) {
    check(Array.isArray(items) && items.length <= 100 && ["all","inProgress","waiting","finished"].includes(filter) && typeof search === "string" && search.length <= 256, "invalidInput");
    const query = search.trim().toLocaleLowerCase();
    return items.filter(item => (filter === "all" || (filter === "inProgress" && ["queued","running"].includes(item.state)) || (filter === "waiting" && ["waiting_for_volume","paused"].includes(item.state)) || (filter === "finished" && ["completed","failed","cancelled"].includes(item.state))) &&
      (taskName(item, translate) + " " + item.id).toLocaleLowerCase().includes(query));
  }
  return { createFixtureTaskSource, createClientTaskSource, createTaskPager, taskName, filterTasks };
});

(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory(require("./model.js"));
  else root.MacNASNotifications = Object.freeze(factory(root.MacNASModel));
})(globalThis, function (M) {
  "use strict";
  const locks = new WeakMap(), encoder = new TextEncoder();
  const codes = new Set(["invalidInput","invalidResponse","unsupported","denied","readOnly","unavailable","budgetExceeded","replay","collision","missingVolume","unsafePath","unsafeFile","integrity","database","busy","expired","staleState","interrupted","timedOut","cancelled","pluginFailed","invalidSchema"]);
  const types = { queued: ["queued"], claimed: ["running"], checkpoint: ["running"], completed: ["completed"], cancelled: ["cancelled"], deferred: ["queued","waiting_for_volume","failed"], failed: ["failed"] };
  const check = (ok, code = "invalidResponse") => { if (!ok) throw new M.ServiceError(code); };
  const codeOf = error => error instanceof M.ServiceError && codes.has(error.code) ? error.code : "unavailable";
  const freeze = value => { if (value && typeof value === "object") { Object.values(value).forEach(freeze); Object.freeze(value); } return value; };
  function text(value, maximum = 128, code = "invalidResponse") {
    check(typeof value === "string" && value.length > 0 && value.length <= maximum && value.isWellFormed() && !value.includes("\0") && encoder.encode(value).length <= maximum, code); return value;
  }
  function event(raw) {
    check(raw && Object.getPrototypeOf(raw) === Object.prototype && Object.keys(raw).length === 5 && ["sequence","job_id","revision","type","state"].every(key => Object.hasOwn(raw,key)));
    check(Number.isSafeInteger(raw.sequence) && raw.sequence > 0 && Number.isSafeInteger(raw.revision) && raw.revision > 0);
    check(typeof raw.type === "string" && Object.hasOwn(types,raw.type) && types[raw.type].includes(raw.state)); text(raw.job_id);
    return freeze({ sequence: raw.sequence, jobID: raw.job_id, revision: raw.revision, type: raw.type, state: raw.state });
  }
  async function create(kind, provider, operations, options = {}) {
    check(options && Object.getPrototypeOf(options) === Object.prototype && Reflect.ownKeys(options).every(key => ["consumerID","capacity"].includes(key) && Object.hasOwn(Object.getOwnPropertyDescriptor(options,key),"value")),"invalidInput");
    const { consumerID, capacity = 100 } = options;
    text(consumerID,128,"invalidInput"); check(Number.isSafeInteger(capacity) && capacity >= 1 && capacity <= 100,"invalidInput");
    let info;
    try { info = await operations.overview(); } catch (error) { throw new M.ServiceError(codeOf(error)); }
    check(info?.source === kind && info.apiVersion === 1 && info.databaseSchema === 3 && info.physicalPool === "unbound");
    text(info.userID); check(["administrator","reader"].includes(info.role) && ["synthetic_development","read_only_recovery","rolled_back_recovery"].includes(info.mode));
    const context = freeze({ source: kind, userID: info.userID, role: info.role, mode: info.mode });
    if (!locks.has(provider)) locks.set(provider,new Map());
    const active = locks.get(provider);
    let generation = 0, target = null, fatal = false;
    let view = freeze({ phase: "idle", items: [], capacity, full: false, confirmedThrough: 0, error: null, ackRetryRequired: false, unavailable: false });
    const update = values => { view = freeze({ ...view, ...values }); return view; };
    function ready() {
      check(view.phase !== "closed" && !fatal && !operations.isClosed?.(),"unavailable");
      check(context.mode === "synthetic_development","readOnly");
      check(!["polling","acknowledging"].includes(view.phase) && !active.has(consumerID),"busy");
      check(active.size < 32,"budgetExceeded");
    }
    async function perform(phase, operation, apply) {
      const epoch = generation; active.set(consumerID,true); update({ phase, error: null });
      try {
        const result = await operation();
        if (epoch !== generation) return view;
        check(!operations.isClosed?.(),"unavailable");
        apply(result); return view;
      } catch (error) {
        if (epoch !== generation) return view;
        const code = codeOf(error); fatal = code === "invalidResponse" || !!operations.isClosed?.();
        update({ phase: "error", error: code, ackRetryRequired: target !== null, unavailable: fatal });
        throw new M.ServiceError(code);
      } finally { active.delete(consumerID); }
    }
    return Object.freeze({
      context, snapshot() {
        if (view.phase !== "closed" && operations.isClosed?.()) update({ phase: "error", unavailable: true, error: view.error || "unavailable" });
        return view;
      },
      dispose() { if (view.phase === "closed") return; generation++; target = null; update({ phase: "closed", items: [], full: false, confirmedThrough: 0, error: null, ackRetryRequired: false, unavailable: true }); },
      async poll() {
        ready(); check(target === null,"staleState"); check(!view.full,"budgetExceeded");
        return perform("polling",() => operations.poll(consumerID,capacity),raw => {
          check(Array.isArray(raw) && raw.length <= capacity);
          const incoming = raw.map(event);
          for (let i = 0; i < incoming.length; i++) check(incoming[i].sequence > (i ? incoming[i-1].sequence : view.confirmedThrough));
          const merged = new Map(view.items.map(item => [item.sequence,item]));
          for (const item of incoming) {
            const old = merged.get(item.sequence);
            check(!old || ["jobID","revision","type","state"].every(key => old[key] === item[key])); merged.set(item.sequence,item);
          }
          // An over-budget batch is an explicit failure; never evict or ACK unseen/unconfirmed data.
          check(merged.size <= capacity,"budgetExceeded");
          const items = [...merged.values()].sort((a,b) => b.sequence-a.sequence);
          update({ phase: "ready", items, full: items.length === capacity, error: null });
        });
      },
      async acknowledge() {
        ready(); check(view.items.length > 0,"denied");
        if (target === null) target = view.items[0].sequence;
        return perform("acknowledging",() => operations.acknowledge(consumerID,target),result => {
          check(result === true); const confirmedThrough = target; target = null;
          update({ phase: "ready", items: [], full: false, confirmedThrough, error: null, ackRetryRequired: false });
        });
      }
    });
  }
  async function createFixtureNotificationView(api, session, options) {
    check(api?.source === "fixture" && ["overview","pollEvents","acknowledgeEvents"].every(key => typeof api[key] === "function"),"unavailable");
    return create("fixture",api,{ overview: () => api.overview(session), poll: (id,limit) => api.pollEvents(id,session,limit),
      acknowledge: async (id,through) => { await api.acknowledgeEvents(id,through,session); return true; } },options);
  }
  async function createClientNotificationView(client, options) {
    check(client?.source === "fixture-host-client" && !client.closed && ["overview","pollEvents","acknowledgeEvents"].every(key => typeof client[key] === "function"),"unavailable");
    return create("fixture-host",client,{ overview: () => client.overview(), poll: (id,limit) => client.pollEvents(id,limit),
      acknowledge: (id,through) => client.acknowledgeEvents(id,through), isClosed: () => client.closed },options);
  }
  function notificationTaskName(item, tasks, translate) {
    check(Array.isArray(tasks) && tasks.length <= 102 && typeof translate === "function","invalidInput");
    const name = tasks.find(task => task.id === item.jobID)?.name;
    if (name?.kind === "text") { if (name.value === "") return ""; return text(name.value,1024); }
    if (name?.kind === "key" && ["jobHash","jobLabels","jobVolume","jobVerify","jobComplete","jobFamily"].includes(name.value)) return translate(name.value);
    return translate("notificationTaskFallback");
  }
  return { createFixtureNotificationView, createClientNotificationView, notificationTaskName };
});

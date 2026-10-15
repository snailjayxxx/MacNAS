(function () {
  "use strict";
  const M = window.MacNASModel, I = window.MacNASI18n;
  const api = M.createFixtureAdapter();
  const $ = (query, root = document) => root.querySelector(query);
  const paths = {
    nas:"M5 3h14v18H5z M8 7h6m-6 5h6m-6 5h6m3-10h.01m-.01 5h.01m-.01 5h.01",
    overview:"M3 11 12 3l9 8M5 10v11h5v-7h4v7h5V10",
    files:"M3 7V5h6l2 2h10v13H3z M3 10h18",
    storage:"M5 3h14v18H5z M8 7h8m-8 4h8m-8 6h4m4 0h.01",
    apps:"M4 4h6v6H4z M14 4h6v6h-6z M4 14h6v6H4z M14 14h6v6h-6z",
    tasks:"M8 5h13M8 12h13M8 19h13M3 5h.01M3 12h.01M3 19h.01",
    settings:"m9 3-.5 2-2 1-2-.5-2 3 1.5 1.5v3L2.5 15l2 3 2-.5 2 1L9 21h4l.5-2 2-1 2 .5 2-3-1.5-2.5v-3L20 8l-2-3-2 .5-2-1-.5-1.5z M14 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0",
    preferences:"M20 21v-2a6 6 0 0 0-6-6h-4a6 6 0 0 0-6 6v2 M16 6a4 4 0 1 1-8 0 4 4 0 0 1 8 0",
    user:"M20 21v-2a6 6 0 0 0-6-6h-4a6 6 0 0 0-6 6v2 M16 6a4 4 0 1 1-8 0 4 4 0 0 1 8 0",
    bell:"M18 8a6 6 0 0 0-12 0c0 7-3 8-3 8h18s-3-1-3-8M10 21h4",
    search:"M16 10a6 6 0 1 1-12 0 6 6 0 0 1 12 0m-2 4 6 6",
    close:"m6 6 12 12M6 18 18 6",minus:"M5 12h14",maximize:"M5 5h14v14H5z",restore:"M8 4h12v12M4 8h12v12H4z",
    chevron:"m8 10 4 4 4-4",arrow:"m9 5 7 7-7 7",back:"m15 5-7 7 7 7",plus:"M12 5v14M5 12h14",
    refresh:"M20 10a8 8 0 1 0-2 8m2-15v7h-7",info:"M12 8h.01M11 11h1v6m9-5a9 9 0 1 1-18 0 9 9 0 0 1 18 0",
    check:"m5 12 4 4L19 6",clock:"M12 7v5l3 2m6-2a9 9 0 1 1-18 0 9 9 0 0 1 18 0",
    lock:"M5 10h14v11H5z M8 10V6a4 4 0 0 1 8 0v4m-4 5v2",
    shield:"m12 3 8 3v6c0 5-8 9-8 9s-8-4-8-9V6z M8 12l3 3 5-6",
    activity:"M2 12h5l3-8 4 16 3-8h5",file:"M5 3h9l5 5v13H5z M14 3v6h5M8 13h8m-8 4h6",
    folder:"M3 7V5h6l2 2h10v13H3z",list:"M8 5h13M8 12h13M8 19h13M3 5h.01M3 12h.01M3 19h.01",
    resize:"m7 20 13-13m-6 13 6-6",error:"m12 3 10 18H2z M12 9v5m0 3h.01",
    waiting:"M7 3h10v3l-4 6 4 6v3H7v-3l4-6-4-6z",
    diagnostics:"M4 5h16v14H4z M7 12h2l2-4 2 8 2-4h2"
  };
  function el(tag, className = "", text) {
    const element = document.createElement(tag); if (className) element.className = className;
    if (text !== undefined) element.textContent = String(text); return element;
  }
  function icon(name) {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 24 24"); svg.setAttribute("class", "icon"); svg.setAttribute("aria-hidden", "true");
    const path = document.createElementNS(svg.namespaceURI, "path"); path.setAttribute("d", paths[name] || paths.info); svg.append(path); return svg;
  }
  function addIcons(root = document) { root.querySelectorAll("[data-icon]").forEach(node => { if (!node.querySelector(":scope > svg")) node.prepend(icon(node.dataset.icon)); }); }
  function button(text, className, handler, iconName) {
    const node = el("button", className, text); node.type = "button"; if (iconName) node.prepend(icon(iconName));
    if (handler) node.addEventListener("click", handler); return node;
  }
  let storage;
  try { storage = window.localStorage; } catch { storage = { getItem: () => null, setItem: () => { throw new Error("unavailable"); } }; }
  const prefs = M.readPreferences(storage);
  const state = { prefs, session: null, overview: null, jobs: [], events: [], ack: 0, consumer: "desktop-preview", scenario: "owner", epoch: 0, z: 10, windows: new Map(), active: null, panel: null, modal: null };
  const t = (key, vars) => I.t(prefs.locale, key, vars);
  const appIDs = ["overview", "files", "storage", "apps", "tasks", "settings"];
  const canWrite = () => state.overview?.mode === "synthetic_development";
  const isOwner = () => state.overview?.role === "administrator";
  const jobName = job => job.title || t(job.titleKey || "tasks");
  function persist() { return M.savePreferences(storage, prefs); }
  let toastTimer;
  function toast(message) {
    clearTimeout(toastTimer); $("#toast").textContent = message; $("#toast").hidden = false;
    toastTimer = setTimeout(() => { $("#toast").hidden = true; }, 3500);
  }
  function errorMessage(error) { return t(I.dictionaries[prefs.locale][error?.code] ? error.code : "error"); }
  function appIcon(id) { const box = el("span", "app-icon " + id); box.append(icon(id)); return box; }
  function namedIconButton(key, iconName, handler) {
    const node = button("", "icon-button", handler, iconName); node.setAttribute("aria-label", t(key)); node.title = t(key); return node;
  }
  function availableApps() { return appIDs.filter(id => id !== "settings" || isOwner()); }
  function area() { return { width: $("#desktop").clientWidth, height: $("#desktop").clientHeight }; }
  function applyGeometry(win) {
    const g = win.geometry; Object.assign(win.element.style, { left: g.x + "px", top: g.y + "px", width: g.w + "px", height: g.h + "px" });
    win.element.classList.toggle("maximized", win.maximized);
  }
  function saveGeometry(win) { prefs.windows[win.id] = { ...win.geometry }; persist(); }
  function focusWindow(id) {
    const win = state.windows.get(id); if (!win) return;
    win.minimized = false; win.element.hidden = false; win.element.style.zIndex = String(++state.z); state.active = id;
    for (const [key, other] of state.windows) other.element.classList.toggle("inactive", key !== id);
    renderDock();
  }
  function closeWindow(id) {
    const win = state.windows.get(id); if (!win) return;
    saveGeometry(win); win.element.remove(); state.windows.delete(id);
    if (state.active === id) state.active = [...state.windows.values()].filter(w => !w.minimized).at(-1)?.id || null;
    if (state.active) focusWindow(state.active); else renderDock();
    const target = $("[data-open-app='" + id + "']"); target?.focus();
  }
  function minimizeWindow(id) {
    const win = state.windows.get(id); if (!win) return;
    win.minimized = true; win.element.hidden = true;
    const next = [...state.windows.values()].filter(w => !w.minimized).at(-1);
    state.active = next?.id || null; if (next) focusWindow(next.id); else renderDock();
  }
  function maximizeWindow(id) { const win = state.windows.get(id); if (!win) return; win.maximized = !win.maximized; applyGeometry(win); renderWindowChrome(win); }
  function wirePointer(win, handle, mode) {
    handle.addEventListener("pointerdown", event => {
      if (event.button !== 0 || event.target.closest("button") && mode !== "resize" || win.maximized || window.innerWidth <= 680) return;
      event.preventDefault(); focusWindow(win.id);
      const start = { x: event.clientX, y: event.clientY, ...win.geometry }, pointer = event.pointerId;
      // Store coordinates separately: window origin and pointer origin are different values.
      const pointerX = event.clientX, pointerY = event.clientY;
      handle.setPointerCapture(pointer);
      const move = current => {
        const dx = current.clientX - pointerX, dy = current.clientY - pointerY;
        win.geometry = M.geometry(mode === "resize" ? { ...start, w: start.w + dx, h: start.h + dy } : { ...start, x: start.x + dx, y: start.y + dy }, area());
        applyGeometry(win);
      };
      const end = () => { handle.removeEventListener("pointermove", move); handle.removeEventListener("pointerup", end); handle.removeEventListener("pointercancel", end); if (handle.hasPointerCapture(pointer)) handle.releasePointerCapture(pointer); saveGeometry(win); };
      handle.addEventListener("pointermove", move); handle.addEventListener("pointerup", end); handle.addEventListener("pointercancel", end);
    });
  }
  function renderWindowChrome(win) {
    const titlebar = win.titlebar; titlebar.replaceChildren();
    const title = el("span", "window-title"); title.id = "title-" + win.id; title.append(icon(win.id), el("span", "", t(win.id)));
    const controls = el("div", "window-controls");
    for (const [action, key, name, handler] of [
      ["minimize", "minimize", "minus", () => minimizeWindow(win.id)],
      ["maximize", win.maximized ? "restore" : "maximize", win.maximized ? "restore" : "maximize", () => maximizeWindow(win.id)],
      ["close", "close", "close", () => closeWindow(win.id)]
    ]) { const node = namedIconButton(key, name, handler); node.dataset.action = action; controls.append(node); }
    titlebar.append(title, controls);
    win.element.setAttribute("aria-labelledby", title.id); win.resize.setAttribute("aria-label", t("resize")); win.resize.title = t("resize");
  }
  async function openWindow(id, { route = false } = {}) {
    const epoch = state.epoch;
    let denied = null;
    try { await api.authorizeApp(id, state.session); } catch (error) { denied = error; }
    if (epoch !== state.epoch) return;
    if (!M.apps.includes(id)) id = "overview";
    hidePanels();
    if (state.windows.has(id)) { const existing=state.windows.get(id); if (denied) renderDenied(existing, denied); else await renderWindow(existing); if(epoch!==state.epoch || !existing.element.isConnected)return; focusWindow(id); existing.element.focus(); return; }
    const element = el("section", "app-window"); element.dataset.app = id; element.setAttribute("role", "region"); element.tabIndex = -1;
    const titlebar = el("header", "titlebar"), content = el("div", "window-content");
    const resize = namedIconButton("resize", "resize"); resize.classList.add("resize-handle");
    const offset = state.windows.size * 20;
    const win = { id, element, titlebar, content, resize, maximized: false, minimized: false, geometry: M.geometry(prefs.windows[id] || { x: (area().width - 1060) / 2 + offset, y: 32 + offset, w: 1060, h: 680 }, area()), view: { filter: "all", search: "", path: [], grid: false } };
    state.windows.set(id, win); element.append(titlebar, content, resize); $("#windows").append(element);
    element.addEventListener("pointerdown", () => { if (state.active !== id) focusWindow(id); });
    titlebar.addEventListener("dblclick", event => { if (!event.target.closest("button") && window.innerWidth > 680) maximizeWindow(id); });
    wirePointer(win, titlebar, "move"); wirePointer(win, resize, "resize");
    resize.addEventListener("keydown", event => {
      if (!["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(event.key)) return;
      event.preventDefault(); const amount = event.shiftKey ? 50 : 10;
      win.geometry = M.geometry({ ...win.geometry, w: win.geometry.w + (event.key === "ArrowRight" ? amount : event.key === "ArrowLeft" ? -amount : 0), h: win.geometry.h + (event.key === "ArrowDown" ? amount : event.key === "ArrowUp" ? -amount : 0) }, area());
      applyGeometry(win); saveGeometry(win);
    });
    renderWindowChrome(win); applyGeometry(win);
    if (denied) renderDenied(win, denied); else await renderWindow(win);
    if (epoch !== state.epoch || !state.windows.has(id)) return;
    focusWindow(id); win.element.focus(); saveGeometry(win);
    if (!route && location.hash !== "#" + id) { try { history.replaceState(null, "", "#" + id); } catch {} }
  }
  function buildPage(win, introKey) {
    win.content.replaceChildren();
    const sidebar = el("nav", "sidebar"); sidebar.setAttribute("aria-label", t("appMenu"));
    sidebar.append(el("div", "sidebar-brand", "WORKSPACE"));
    const nav = el("div", "sidebar-nav");
    for (const id of availableApps()) {
      const node = button(t(id), win.id === id ? "selected" : "", () => openWindow(id), id);
      node.dataset.openApp = id; if (win.id === id) node.setAttribute("aria-current", "page"); nav.append(node);
    }
    const foot = el("div", "sidebar-foot"); foot.append(icon("shield"), el("p", "", t("demoNote"))); sidebar.append(nav, foot);
    const page = el("div", "page");
    const ribbon = el("div", "demo-ribbon" + (canWrite() ? "" : " recovery"));
    ribbon.append(icon(canWrite() ? "info" : "lock"), el("span", "", t(canWrite() ? "demoHint" : "recoverHint")));
    const heading = el("div", "page-header"), title = el("div");
    title.append(el("span", "eyebrow", "MacNAS / " + t(win.id)), el("h1", "", t(win.id)), el("p", "", t(introKey)));
    heading.append(title); page.append(ribbon, heading); win.content.append(sidebar, page);
    return { page, heading, title };
  }
  function renderDenied(win, error) {
    win.content.replaceChildren();
    const area = el("div", "page denied-state");
    area.append(icon("lock"), el("h2", "", errorMessage(error)), el("p", "", t("demoShort")), button(t("returnOverview"), "secondary-button", () => openWindow("overview")));
    win.content.append(area);
  }
  async function renderWindow(win) {
    const epoch = state.epoch;
    try {
      await api.authorizeApp(win.id, state.session);
      if (epoch !== state.epoch) return;
      if (win.id === "overview") renderOverview(win);
      if (win.id === "tasks") renderTasks(win);
      if (win.id === "files") await renderFiles(win);
      if (win.id === "storage") renderStorage(win);
      if (win.id === "apps") renderApps(win);
      if (win.id === "settings" || win.id === "preferences") renderPreferences(win);
    } catch (error) { if (epoch === state.epoch) renderDenied(win, error); }
  }
  function statePill(job) { return el("span", "state-pill " + job.state, t(job.state)); }
  function progress(job) { return job.checkpoint?.step === "completed" ? 2 : job.checkpoint?.step === "prepared" ? 1 : 0; }
  function miniTask(job) {
    const row = el("div", "mini-task"), mark = el("span", "mini-task-icon"); mark.append(icon(job.state === "waiting_for_volume" ? "storage" : "file"));
    const copy = el("div", "mini-task-main"); copy.append(el("strong", "", jobName(job)), el("p", "", t("stepProgress", { count: progress(job) })));
    row.append(mark, copy, statePill(job)); return row;
  }
  function sectionTitle(titleKey, action) {
    const header = el("div", "section-title"); header.append(el("h3", "", t(titleKey)));
    if (action) header.append(button(t("viewAll"), "text-button", action, "arrow")); return header;
  }
  function renderOverview(win) {
    const { page, heading, title } = buildPage(win, "overviewIntro");
    $("h1", title).textContent = t(isOwner() ? "greeting" : "familyGreeting");
    heading.append(el("span", "pill", t("demoShort")));
    const grid = el("div", "overview-grid"), capacity = el("section", "card space-card"), header = el("div", "card-header");
    header.append(el("h3", "", t("capacityTitle")), icon("storage")); capacity.append(header);
    const content = el("div", "space-content"), ring = el("div", "capacity-ring"), ringText = el("div", "ring-label"), number = el("strong", "", "35");
    number.append(el("small", "", "TB")); ringText.append(number, el("small", "", t("logicalReference"))); ring.append(ringText);
    ring.setAttribute("role", "img"); ring.setAttribute("aria-label", t("logicalReference") + " 35 TB; " + t("capacityFoot"));
    const legend = el("div", "space-legend");
    for (const [key, size] of [["photos", "22 TB"], ["video", "9 TB"], ["documents", "4 TB"]]) {
      const row = el("div", "legend-row"); row.append(el("i", "legend-dot " + key), el("span", "", t(key)), el("strong", "", size)); legend.append(row);
    }
    content.append(ring, legend); capacity.append(content, el("p", "capacity-foot", t("capacityFoot")));
    const side = el("div", "overview-side");
    for (const [key, count, name, color] of [["activeTasks", state.overview.active, "tasks", ""], ["completedTasks", state.overview.completed, "check", "green"]]) {
      const card = el("section", "card metric-card"), mark = el("span", "metric-icon " + color), copy = el("div"), number = el("strong", "metric-number", count);
      mark.append(icon(name)); copy.append(el("p", "metric-label", t(key)), number); card.append(mark, copy); side.append(card);
    }
    const pool = el("div", "pool-note"), poolCopy = el("div"); poolCopy.append(el("strong", "", t("poolUnbound")), el("p", "", t("poolHint")));
    pool.append(icon("shield"), poolCopy, button(t("seeStorage"), "text-button", () => openWindow("storage"), "arrow"));
    grid.append(capacity, side, pool); page.append(grid, sectionTitle("recentTasks", () => openWindow("tasks")));
    const recent = el("div"); for (const job of state.jobs.slice(0, 2)) recent.append(miniTask(job)); page.append(recent);
    page.append(sectionTitle("installedApps", () => openWindow("apps")));
    const cards = el("div", "app-cards"); cards.append(sampleAppCard("diagnostics"), sampleAppCard("fileIndex")); page.append(cards);
  }
  function sampleAppCard(app) {
    const node = button("", "app-card", () => showAppDetail(app)), mark = appIcon(app === "diagnostics" ? "overview" : "files"), copy = el("div");
    copy.append(el("strong", "", t(app)), el("p", "", t(app === "diagnostics" ? "diagnosticsDesc" : "fileIndexDesc"))); node.append(mark, copy); return node;
  }

  function searchField(key, value, handler) {
    const label = el("label", "search-field"), input = el("input"); input.type = "search"; input.autocomplete = "off"; input.placeholder = t(key); input.setAttribute("aria-label", t(key)); input.value = value;
    input.addEventListener("input", handler); label.append(icon("search"), input); return label;
  }
  function renderTasks(win) {
    const { page, heading } = buildPage(win, "taskIntro");
    if (isOwner()) { const create = button(t("newTask"), "primary-button", createTaskModal, "plus"); create.dataset.createTask = ""; create.disabled = !canWrite(); if (!canWrite()) create.title = t("readOnlyAction"); heading.append(create); }
    if (!canWrite()) page.append(el("p", "readonly-note", t("readOnlyAction")));
    const toolbar = el("div", "task-toolbar"), filters = el("div", "filter-tabs");
    filters.setAttribute("role", "group"); filters.setAttribute("aria-label", t("status"));
    for (const key of ["all", "inProgress", "waiting", "finished"]) {
      const tab = button(t(key), win.view.filter === key ? "active" : "", () => {
        win.view.filter = key;
        for (const node of filters.children) { node.classList.toggle("active", node.dataset.filter === key); node.setAttribute("aria-pressed", String(node.dataset.filter === key)); }
        renderTaskRows(win);
      }); tab.dataset.filter = key; tab.setAttribute("aria-pressed", String(win.view.filter === key)); filters.append(tab);
    }
    const search = searchField("searchTasks", win.view.search, event => { win.view.search = event.target.value; renderTaskRows(win); });
    search.querySelector("input").dataset.taskSearch = "";
    toolbar.append(filters, search); page.append(toolbar);
    win.taskList = el("div", "task-list"); page.append(win.taskList); renderTaskRows(win);
  }
  function renderTaskRows(win) {
    win.taskList.replaceChildren();
    const filtered = state.jobs.filter(job => {
      const matches = win.view.filter === "all" || (win.view.filter === "inProgress" && ["queued", "running"].includes(job.state)) || (win.view.filter === "waiting" && ["waiting_for_volume", "paused"].includes(job.state)) || (win.view.filter === "finished" && ["completed", "failed", "cancelled"].includes(job.state));
      return matches && jobName(job).toLocaleLowerCase().includes(win.view.search.trim().toLocaleLowerCase());
    });
    if (!filtered.length) { win.taskList.append(emptyState("tasks", "noTasks", "noTaskHint")); return; }
    for (const job of filtered) {
      const row = el("article", "task-row " + job.state); row.dataset.jobId = job.id; row.dataset.state = job.state;
      const mark = el("span", "mini-task-icon"); mark.append(icon(job.kind === "fixtureHash" ? "file" : "tasks"));
      const copy = el("div", "task-copy"), top = el("div", "task-top"); top.append(el("h3", "", jobName(job)), statePill(job));
      const meta = el("div", "task-meta"); meta.append(el("span", "", t("attempts", { count: job.attempts, max: job.max_attempts })), el("span", "", t("stepProgress", { count: progress(job) })));
      const bar = el("div", "progress-track"), fill = el("span"); fill.style.width = progress(job) * 50 + "%"; bar.append(fill); bar.setAttribute("role", "progressbar"); bar.setAttribute("aria-label", jobName(job) + " / " + t("progress")); bar.setAttribute("aria-valuemin", "0"); bar.setAttribute("aria-valuemax", "2"); bar.setAttribute("aria-valuenow", String(progress(job)));
      copy.append(top, meta, bar);
      if (job.last_error) copy.append(el("p", "task-error", t(job.state === "queued" ? "autoRetry" : job.state === "failed" ? "retryExhausted" : "missingVolume")));
      const actions = el("div", "task-actions"); actions.append(button(t("details"), "text-button", () => taskDetail(job)));
      if (!["failed", "completed", "cancelled"].includes(job.state)) {
        const cancel = button(t("cancelTask"), "secondary-button", () => cancelTaskModal(job)); cancel.dataset.cancelJob = job.id; cancel.disabled = !canWrite(); if (!canWrite()) cancel.title = t("readOnlyAction"); actions.append(cancel);
      }
      row.append(mark, copy, actions); win.taskList.append(row);
    }
  }
  function emptyState(name, title, hint) {
    const node = el("div", "empty-state"); node.append(icon(name), el("h3", "", t(title))); if (hint) node.append(el("p", "", t(hint))); return node;
  }
  function taskDetail(job) {
    const content = el("div"), list = el("dl", "detail-grid");
    for (const [key, value] of [["status", t(job.state)], ["progress", t("stepProgress", { count: progress(job) })], ["checkpoint", t(job.checkpoint?.step === "completed" ? "stepComplete" : job.checkpoint?.step === "prepared" ? "prepared" : "notStarted")], ["actions", t("attempts", { count: job.attempts, max: job.max_attempts })]]) list.append(el("dt", "", t(key)), el("dd", "", value));
    content.append(list); if (job.last_error) content.append(el("p", "", t(job.last_error)));
    showModal(jobName(job), content, [{ key: "done", style: "secondary-button", action: closeModal }]);
  }
  function cancelTaskModal(job) {
    const epoch = state.epoch, session = state.session, content = el("div"); content.append(el("p", "", t("cancelHint")));
    showModal(t("cancelQuestion", { name: jobName(job) }), content, [
      { key: "back", style: "secondary-button", action: closeModal },
      { key: "cancelConfirm", style: "danger-button", action: async () => {
        await api.cancelJob(job.id, session); if (epoch !== state.epoch) return;
        closeModal(); await refreshData(); toast(t("cancelledToast")); focusActiveHeading();
      }}
    ]);
  }
  function createTaskModal() {
    const content = el("div"), hint = el("p", "", t("newTaskHint")), label = el("label", "", t("taskValue")), input = el("input");
    input.id = "new-task-value"; input.type = "text"; input.maxLength = 80; input.placeholder = t("taskPlaceholder"); input.value = t("jobNew"); label.htmlFor = input.id;
    content.append(hint, label, input);
    const epoch = state.epoch, session = state.session, id = "preview-" + crypto.randomUUID();
    showModal(t("newTask"), content, [
      { key: "back", style: "secondary-button", action: closeModal },
      { key: "addToQueue", style: "primary-button", action: async () => {
        await api.submitLabelJob({ id, key: id, value: input.value.trim() }, session); if (epoch !== state.epoch) return;
        closeModal(); await refreshData(); toast(t("taskCreated")); focusActiveHeading();
      }}
    ]); input.focus(); input.select();
  }
  async function renderFiles(win) {
    const { page } = buildPage(win, "fileIntro"), epoch = state.epoch;
    const crumbs = el("nav", "file-breadcrumbs"); crumbs.setAttribute("aria-label", t("root"));
    crumbs.append(button(t("root"), "", () => { win.view.path = []; renderWindow(win); }));
    win.view.path.forEach((part, index) => { crumbs.append(icon("arrow"), button(t(part.nameKey), "", () => { win.view.path = win.view.path.slice(0, index + 1); renderWindow(win); })); });
    page.append(crumbs);
    const toolbar = el("div", "files-toolbar");
    const search = searchField("searchFiles", win.view.search, event => { win.view.search = event.target.value; renderFileRows(win); });
    const view = namedIconButton("fileView", win.view.grid ? "list" : "apps", () => { win.view.grid = !win.view.grid; renderWindow(win); });
    toolbar.append(search, view); page.append(toolbar, el("p", "content-note", t("sampleFiles")));
    const parent = win.view.path.at(-1)?.id || "", response = await api.listFiles(parent, state.session);
    if (epoch !== state.epoch || !win.element.isConnected) return;
    win.files = response; win.fileList = el("div", "file-list" + (win.view.grid ? " grid" : "")); page.append(win.fileList); renderFileRows(win);
  }
  function renderFileRows(win) {
    if (!win.fileList) return;
    win.fileList.replaceChildren();
    const visible = win.files.filter(file => t(file.nameKey).toLocaleLowerCase().includes(win.view.search.trim().toLocaleLowerCase()));
    if (!visible.length) { win.fileList.append(emptyState("files", "emptyFolder")); return; }
    for (const file of visible) {
      const row = button("", "file-row", async () => {
        if (file.kind === "folder") { win.view.path.push({ id: file.id, nameKey: file.nameKey }); win.view.search = ""; await renderWindow(win); }
        else {
          const epoch = state.epoch; const data = await api.previewFile(file.id, state.session); if (epoch !== state.epoch) return;
          const content = el("div"); content.append(el("p", "", t("sampleFiles")), el("div", "preview-content", t(data.previewKey))); showModal(t(data.nameKey), content, [{ key: "done", style: "secondary-button", action: closeModal }]);
        }
      });
      row.dataset.fileId = file.id;
      const name = el("span"); name.append(icon(file.kind === "folder" ? "folder" : "file"), el("span", "", t(file.nameKey))); row.append(name, el("span", "", file.size || t("folder")), el("span", "", file.modified)); win.fileList.append(row);
    }
  }
  function renderStorage(win) {
    const { page, heading } = buildPage(win, "storageIntro"); heading.append(el("span", "pill amber", t("storageReady")));
    const hero = el("div", "storage-hero"), copy = el("div"), amount = el("strong", "", "35"); amount.append(el("small", "", "TB"));
    copy.append(el("p", "", t("logicalScale")), amount, el("p", "", t("capacityFoot"))); hero.append(copy, icon("storage")); page.append(hero, sectionTitle("fiveDisks"));
    const disks = el("div", "disk-row"); for (let i = 1; i <= 5; i++) { const disk = el("div", "disk-member"); disk.append(icon("storage"), el("span", "", "0" + i)); disks.append(disk); } page.append(disks, el("p", "content-note", t("noDisks")), sectionTitle("poolStages"));
    const stages = el("div", "stage-list"); ["identify", "bind", "verifyPool", "enable"].forEach((key, i) => { const row = el("div", "stage"); row.append(el("span", "stage-index", i + 1), el("span", "", t(key)), el("small", "", t("pending"))); stages.append(row); });
    page.append(stages, el("p", "content-note", t("storageNotice")));
  }
  function renderApps(win) {
    const { page } = buildPage(win, "appIntro"), cards = el("div", "app-cards"); cards.append(sampleAppCard("diagnostics"), sampleAppCard("fileIndex")); page.append(cards, el("p", "content-note", t("sampleAppHint")));
    const grid = el("div", "permission-grid");
    for (const [name, title, desc] of [["shield", "permissions", "noSandbox"], ["lock", "identity", "mockSession"]]) {
      const card = el("div", "permission-card"); card.append(icon(name), el("h3", "", t(title)), el("p", "", t(desc)), el("span", "pill", t("demoShort"))); grid.append(card);
    } page.append(grid);
  }
  function showAppDetail(app) {
    const content = el("div"), head = el("div", "app-detail"), copy = el("div"); copy.append(el("h3", "", t(app)), el("p", "", t("firstParty"))); head.append(appIcon(app === "diagnostics" ? "overview" : "files"), copy);
    const details = el("dl", "detail-grid");
    for (const [key, value] of [["version", "0.3.0"], ["compatibility", t("macOS15") + " · " + t("appleSilicon")], ["permissions", t(app === "diagnostics" ? "diagPermission" : "indexPermission")]]) details.append(el("dt", "", t(key)), el("dd", "", value));
    content.append(head, el("span", "pill", t("trustedSample")), details, el("p", "", t("noSandbox"))); showModal(t(app), content, [{ key: "done", style: "secondary-button", action: closeModal }]);
  }
  function selectField(id, key, options, current, handler) {
    const row = el("div", "setting-row"), label = el("label", "", t(key)); label.htmlFor = id;
    const select = el("select"); select.id = id; for (const [value, labelKey] of options) { const option = el("option", "", t(labelKey)); option.value = value; select.append(option); } select.value = current; select.addEventListener("change", handler); row.append(label, select); return row;
  }
  function renderPreferences(win) {
    const { page } = buildPage(win, "settingsIntro"), appearance = el("section", "settings-section"); appearance.append(el("h3", "", t("appearance")));
    appearance.append(selectField("language-" + win.id, "language", [["zh-CN", "chinese"], ["ja-JP", "japanese"]], prefs.locale, event => setLocale(event.target.value)));
    const themes = el("div", "setting-row"), choices = el("div", "theme-choice"); themes.append(el("span", "", t("theme")));
    for (const name of ["night", "dawn"]) { const theme = button(t(name), "theme-button" + (prefs.theme === name ? " selected" : ""), () => { prefs.theme = name; document.body.dataset.theme = name; const saved = persist(); refreshViews(); toast(t(saved ? "saved" : "prefsUnavailable")); }); theme.prepend(el("span", "theme-swatch " + name)); theme.dataset.themeChoice = name; theme.setAttribute("aria-pressed", String(prefs.theme === name)); choices.append(theme); }
    themes.append(choices); appearance.append(themes, el("p", "setting-hint", t("localeHint"))); page.append(appearance);
    const scenario = el("section", "settings-section"); scenario.append(el("h3", "", t("demoScenario")));
    const field = selectField("scenario-" + win.id, "identity", [["owner", "scenarioOwner"], ["reader", "scenarioReader"], ["recovery", "scenarioRecovery"]], state.scenario, event => switchScenario(event.target.value, true));
    $("select", field).dataset.scenario = ""; scenario.append(field, el("p", "setting-hint", t("scenarioHint"))); page.append(scenario);
    if (win.id === "settings") {
      const section = el("section", "settings-section"); section.append(el("h3", "", t("accessBoundary")));
      for (const [key, value] of [["identity", "mockSession"], ["systemGrant", "reauthorize"], ["cutover", "notAvailable"]]) { const row = el("div", "setting-row"); row.append(el("span", "", t(key)), el("span", "setting-value", t(value))); section.append(row); }
      section.append(el("p", "setting-hint", t("settingsReadonly"))); page.append(section);
    }
  }
  function showModal(title, content, actions) {
    closeModal(false); hidePanels();
    const previousFocus = document.activeElement, backdrop = el("div", "modal-backdrop"), modal = el("section", "modal"), head = el("header", "modal-header"), heading = el("h2", "", title);
    heading.id = "modal-title"; modal.setAttribute("role", "dialog"); modal.setAttribute("aria-modal", "true"); modal.setAttribute("aria-labelledby", heading.id);
    head.append(heading, namedIconButton("close", "close", closeModal)); const footer = el("div", "modal-actions"), failure = el("p", "modal-error"); failure.setAttribute("role", "alert");
    for (const action of actions) {
      const control = button(t(action.key), action.style, async () => {
        control.disabled = true;
        try { await action.action(); } catch (error) { failure.textContent = errorMessage(error); } finally { control.disabled = false; }
      }); control.dataset.modalAction = action.key; footer.append(control);
    }
    modal.append(head, content, failure, footer); backdrop.append(modal); $("#modal-root").replaceChildren(backdrop); state.modal = { element: modal, previousFocus };
    backdrop.addEventListener("pointerdown", event => { if (event.target === backdrop) closeModal(); });
    $("input,button,select", modal)?.focus();
  }
  function closeModal(restoreFocus = true) {
    const previous = state.modal?.previousFocus; $("#modal-root").replaceChildren(); state.modal = null;
    if (restoreFocus !== false && previous?.isConnected) previous.focus();
  }
  function focusActiveHeading() { const win = state.windows.get(state.active); const heading = win && $("h1", win.content); if (heading) { heading.tabIndex = -1; heading.focus(); } }

  function renderDock() {
    const previous = document.activeElement?.dataset?.dockApp, dock = $("#dock"); dock.replaceChildren(); dock.setAttribute("aria-label", t("dock"));
    const launcher = button("", "dock-button launcher-button", () => togglePanel("launcher")); launcher.append(appIcon("apps"), el("span", "dock-label", t("launcher"))); launcher.setAttribute("aria-label", t("launcher")); dock.append(launcher, el("span", "dock-divider"));
    for (const id of availableApps()) {
      const node = button("", "dock-button" + (state.windows.has(id) ? " active" : ""), () => openWindow(id)); node.dataset.dockApp = id;
      node.append(appIcon(id), el("span", "dock-label", t(id))); node.setAttribute("aria-label", t(id));
      if (state.active === id) node.setAttribute("aria-current", "true"); dock.append(node);
    }
    if (previous) $("[data-dock-app='" + previous + "']", dock)?.focus();
  }
  function renderShortcuts() {
    const shortcuts = $("#shortcuts"); shortcuts.replaceChildren(); shortcuts.setAttribute("aria-label", t("desktop"));
    for (const id of ["files", "storage", "apps", "tasks", "settings"].filter(id => id !== "settings" || isOwner())) {
      const node = button("", "shortcut", () => openWindow(id)); node.dataset.openApp = id; node.append(appIcon(id), el("span", "", t(id))); shortcuts.append(node);
    }
  }
  function renderLauncher() {
    $("#launcher-title").textContent = t("launchTitle"); $("#launcher-hint").textContent = t("shortcut");
    const input = $("#launcher-search"); input.placeholder = t("searchApps"); input.setAttribute("aria-label", t("searchApps"));
    const grid = $("#launcher-grid"); grid.replaceChildren();
    const ids = availableApps().filter(id => t(id).toLocaleLowerCase().includes(input.value.trim().toLocaleLowerCase()));
    for (const id of ids) { const node = button("", "launcher-item", () => openWindow(id)); node.dataset.openApp = id; node.append(appIcon(id), el("span", "", t(id))); grid.append(node); }
    if (!ids.length) grid.append(emptyState("search", "noApps"));
  }
  function eventTitle(event) {
    return t(event.type === "cancelled" ? "eventCancelled" : event.state === "completed" ? "eventCompleted" : event.state === "failed" ? "eventFailed" : event.state === "waiting_for_volume" ? "eventWaiting" : event.type === "queued" ? "eventQueued" : "newEvent");
  }
  function renderNotifications() {
    $("#notifications-title").textContent = t("notifications");
    const count = state.events.filter(e => e.sequence > state.ack).length;
    $("#unread-count").textContent = t(count ? "unread" : "allRead", { count });
    $("#read-all").textContent = t("markRead"); $("#read-all").disabled = !count || !canWrite(); $("#refresh-events").disabled = !canWrite();
    $("#refresh-events").setAttribute("aria-label", t("refresh")); $("#refresh-events").title = t("refresh");
    $("#notification-readonly").hidden = canWrite(); $("#notification-readonly").textContent = t("notificationRecovery"); $("#notification-hint").textContent = t("notificationHint");
    $("#notification-button").setAttribute("aria-label", t("notifications") + (count ? " · " + t("unread", { count }) : ""));
    $(".notification-dot").hidden = !count;
    const list = $("#notification-list"); list.replaceChildren();
    for (const event of state.events) {
      const row = el("article", "notification-item " + event.state + (event.sequence > state.ack ? " unread" : "")); row.dataset.eventSequence = String(event.sequence);
      row.append(icon(event.state === "failed" ? "error" : event.state === "waiting_for_volume" ? "storage" : event.type === "cancelled" ? "close" : event.state === "completed" ? "check" : "tasks"));
      const copy = el("div"), job = state.jobs.find(j => j.id === event.job_id);
      copy.append(el("strong", "", eventTitle(event)), el("p", "", job ? jobName(job) : t("tasks"))); row.append(copy); list.append(row);
    }
    if (!state.events.length) list.append(emptyState("bell", "emptyNotifications"));
  }
  function hidePanels(restore = false) {
    const previous = state.panelFocus;
    for (const id of ["launcher", "notifications", "profile-menu"]) $("#" + id).hidden = true;
    $("#notification-button").setAttribute("aria-expanded", "false"); $("#profile-button").setAttribute("aria-expanded", "false");
    state.panel = null; state.panelFocus = null; if (restore && previous?.isConnected) previous.focus();
  }
  function togglePanel(id) {
    if (state.panel === id) { hidePanels(true); return; }
    hidePanels(); state.panelFocus = document.activeElement; state.panel = id; $("#" + id).hidden = false;
    if (id === "launcher") { $("#launcher-search").value = ""; renderLauncher(); $("#launcher-search").focus(); }
    if (id === "notifications") { renderNotifications(); $("#notification-button").setAttribute("aria-expanded", "true"); $("[data-close-panel]", $("#notifications")).focus(); }
    if (id === "profile-menu") { $("#profile-button").setAttribute("aria-expanded", "true"); $("#open-preferences").focus(); }
  }
  function renderSurroundings() {
    document.documentElement.lang = prefs.locale; document.title = "MacNAS — " + t("workspace"); document.body.dataset.theme = prefs.theme;
    $("#environment-label").textContent = t(canWrite() ? "demo" : "recover"); $("#top-context").textContent = t("demoHint");
    $("#profile-name").textContent = t(isOwner() ? "owner" : "reader"); $("#profile-button").setAttribute("aria-label", t("preferences"));
    $("#search-button").setAttribute("aria-label", t("launcher")); $("#brand-button").setAttribute("aria-label", t("launcher"));
    $("#language-button").textContent = prefs.locale === "zh-CN" ? "中文" : "日本語"; $("#language-button").setAttribute("aria-label", t("language"));
    $("#open-preferences").replaceChildren(icon("user"), document.createTextNode(t("preferences"))); $("#open-about").replaceChildren(icon("info"), document.createTextNode(t("about")));
    const profile = $("#profile-info"); profile.replaceChildren(document.createTextNode(t(isOwner() ? "owner" : "reader")), el("small", "", t(isOwner() ? "administrator" : "readerRole") + " · " + t("demo")));
    for (const close of document.querySelectorAll("[data-close-panel]")) close.setAttribute("aria-label", t("close"));
    renderShortcuts(); renderDock(); renderLauncher(); renderNotifications(); updateClock();
  }
  function updateClock() {
    $("#clock").dateTime = new Date().toISOString();
    $("#clock").textContent = new Intl.DateTimeFormat(prefs.locale, { weekday: "short", hour: "2-digit", minute: "2-digit", hour12: false }).format(new Date());
  }
  function refreshViews() {
    for (const win of state.windows.values()) { renderWindowChrome(win); void renderWindow(win); }
    renderSurroundings();
  }
  async function setLocale(locale) {
    if (!["zh-CN", "ja-JP"].includes(locale)) return;
    closeModal(false); prefs.locale = locale; const saved = persist(); refreshViews(); if (!saved) toast(t("prefsUnavailable"));
  }
  async function refreshData() {
    const epoch = state.epoch, session = state.session;
    const [overview, jobs] = await Promise.all([api.overview(session), api.listJobs(session)]);
    if (epoch !== state.epoch) return;
    state.overview = overview; state.jobs = jobs; state.consumer = "desktop-preview-" + overview.userID;
    if (canWrite()) {
      const events = await api.pollEvents(state.consumer, session);
      if (epoch !== state.epoch) return;
      state.events = M.mergeEvents(state.events, events);
    }
    refreshViews();
  }
  async function switchScenario(scenario, showPreferences = false) {
    const epoch = ++state.epoch, old = state.session;
    document.body.dataset.ready = "false"; closeModal(false); hidePanels();
    for (const win of state.windows.values()) win.element.remove();
    state.windows.clear(); state.active = null; state.jobs = []; state.events = []; state.ack = 0; state.overview = null;
    await api.endSession(old);
    const session = await api.beginFixtureSession(scenario);
    if (epoch !== state.epoch) { await api.endSession(session); return; }
    state.session = session; state.scenario = scenario; await refreshData();
    if (epoch !== state.epoch) return;
    await openWindow("overview", { route: true });
    if (showPreferences) await openWindow("preferences");
    document.body.dataset.ready = "true";
    if (showPreferences) toast(t("sessionChanged"));
  }
  $("#brand-button").addEventListener("click", () => togglePanel("launcher"));
  $("#search-button").addEventListener("click", () => togglePanel("launcher"));
  $("#language-button").addEventListener("click", () => setLocale(prefs.locale === "zh-CN" ? "ja-JP" : "zh-CN"));
  $("#launcher-search").addEventListener("input", renderLauncher);
  $("#notification-button").addEventListener("click", () => togglePanel("notifications"));
  $("#profile-button").addEventListener("click", () => togglePanel("profile-menu"));
  $("#open-preferences").addEventListener("click", () => openWindow("preferences"));
  $("#open-about").addEventListener("click", () => { hidePanels(); const copy = el("div"); copy.append(el("p", "", t("aboutText"))); showModal(t("about"), copy, [{ key: "done", style: "secondary-button", action: closeModal }]); });
  $("#refresh-events").addEventListener("click", async () => { try { await refreshData(); } catch (error) { toast(errorMessage(error)); } });
  $("#read-all").addEventListener("click", async () => {
    const epoch = state.epoch, session = state.session, last = Math.max(0, ...state.events.map(e => e.sequence)), control = $("#read-all");
    control.disabled = true;
    try { await api.acknowledgeEvents(state.consumer, last, session); if (epoch === state.epoch) { state.ack = last; renderNotifications(); } } catch (error) { toast(errorMessage(error)); } finally { if (epoch === state.epoch) renderNotifications(); }
  });
  for (const close of document.querySelectorAll("[data-close-panel]")) close.addEventListener("click", () => hidePanels(true));
  document.addEventListener("pointerdown", event => {
    if (state.panel && !event.target.closest(".floating-panel,#search-button,#notification-button,#profile-button,#brand-button,.launcher-button")) hidePanels();
  });
  document.addEventListener("keydown", event => {
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") { event.preventDefault(); if (!state.modal) togglePanel("launcher"); }
    if (event.key === "Escape") { if (state.modal) closeModal(); else hidePanels(true); }
    const dialog = state.modal?.element || (state.panel === "launcher" ? $("#launcher") : null);
    if (event.key === "Tab" && dialog) {
      const focusable = [...dialog.querySelectorAll("button:not(:disabled),input,select,[tabindex='0']")].filter(node => node.getClientRects().length);
      const first = focusable[0], last = focusable.at(-1);
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
    }
  });
  window.addEventListener("resize", () => { for (const win of state.windows.values()) { win.geometry = M.geometry(win.geometry, area()); applyGeometry(win); } });
  window.addEventListener("hashchange", () => {
    if (!state.session) return;
    const id = location.hash.slice(1); void openWindow(id || "overview", { route: true });
  });
  addIcons(); setInterval(updateClock, 30000);
  void (async () => {
    try {
      const initialRoute = location.hash.slice(1);
      await switchScenario("owner");
      if (initialRoute && initialRoute !== "overview") await openWindow(initialRoute, { route: true });
    } catch (error) { document.body.dataset.ready = "error"; toast(errorMessage(error)); }
  })();
})();

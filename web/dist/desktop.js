(function () {
  "use strict";
  const M = window.MacNASModel, I = window.MacNASI18n, P = window.MacNASTaskPages, N = window.MacNASNotifications, F = window.MacNASDirectoryView, B = window.MacNASFileBrowser, O = window.MacNASFileOperations;
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
  const state = { prefs, session: null, taskSource: null, directorySource: null, overview: null, previewJobs: [], notifications: null, scenario: "owner", epoch: 0, dataRequest: 0, z: 10, windows: new Map(), active: null, panel: null, modal: null, modalEpoch: 0 };
  const t = (key, vars) => I.t(prefs.locale, key, vars);
  const appIDs = ["overview", "files", "storage", "apps", "tasks", "settings"];
  const canWrite = () => state.overview?.mode === "synthetic_development";
  const isOwner = () => state.overview?.role === "administrator";
  const jobName = job => P.taskName(job, t);
  const currentWindow = win => state.windows.get(win.id) === win && win.element.isConnected;
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
    win.pager?.dispose();
    win.filePager?.dispose(); win.previewRequest = (win.previewRequest || 0) + 1;
    win.fileOperation?.dispose();
    if (win.fileModal && state.modal === win.fileModal) closeModal(false);
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
    if (!state.session || !state.taskSource || !state.overview) return;
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
      if (epoch !== state.epoch || !currentWindow(win)) return;
      if (win.id === "overview") renderOverview(win);
      if (win.id === "tasks") renderTasks(win);
      if (win.id === "files") await renderFiles(win);
      if (win.id === "storage") renderStorage(win);
      if (win.id === "apps") renderApps(win);
      if (win.id === "settings" || win.id === "preferences") renderPreferences(win);
    } catch (error) { if (epoch === state.epoch && currentWindow(win)) renderDenied(win, error); }
  }
  function statePill(job) { return el("span", "state-pill " + job.state, t(job.state)); }
  function progress(job) { return job.steps; }
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
    const recent = el("div"); for (const job of state.previewJobs) recent.append(miniTask(job));
    page.append(el("p", "content-note", t("taskPreviewHint")), recent);
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
    if (!win.pager) win.pager = P.createTaskPager({ source: state.taskSource, pageSize: 3 });
    const { page, heading } = buildPage(win, "taskIntro");
    if (isOwner()) { const create = button(t("newTask"), "primary-button", () => createTaskModal(win), "plus"); win.taskCreate = create; create.dataset.createTask = ""; create.disabled = !canWrite(); if (!canWrite()) create.title = t("readOnlyAction"); heading.append(create); }
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
    search.querySelector("input").dataset.taskSearch = ""; search.querySelector("input").maxLength = 128;
    toolbar.append(filters, search); page.append(toolbar);
    page.append(el("p", "content-note task-scope", t("taskPageScope")));
    const navigation = el("div", "task-pagination"), actions = el("div", "task-page-actions");
    win.taskCount = el("p", "toolbar-count"); win.taskCount.setAttribute("role", "status"); win.taskCount.setAttribute("aria-live", "polite"); win.taskCount.tabIndex = -1;
    win.taskReload = button(t("reloadTasks"), "secondary-button", () => moveTaskPage(win, "reload"), "refresh"); win.taskReload.dataset.taskReload = "";
    win.taskNext = button(t("nextTaskPage"), "secondary-button", () => moveTaskPage(win, "next"), "arrow"); win.taskNext.dataset.taskNext = "";
    actions.append(win.taskReload, win.taskNext); navigation.append(win.taskCount, actions); page.append(navigation);
    win.taskFailure = el("p", "readonly-note"); win.taskFailure.setAttribute("role", "alert"); page.append(win.taskFailure);
    win.taskList = el("div", "task-list"); page.append(win.taskList);
    win.taskEnd = el("p", "content-note"); page.append(win.taskEnd); renderTaskRows(win);
    if (win.pager.snapshot().phase === "idle") void moveTaskPage(win, "reload", false);
  }
  async function moveTaskPage(win, direction, focus = true) {
    if (!currentWindow(win)) return;
    const epoch = state.epoch, pending = win.pager[direction](); renderTaskRows(win);
    let succeeded = true;
    try { await pending; } catch { succeeded = false; }
    if (epoch !== state.epoch || !currentWindow(win)) return false;
    renderTaskRows(win); if (focus && !state.modal) win.taskCount.focus(); return succeeded;
  }
  function renderTaskRows(win) {
    const view = win.pager.snapshot(), busy = ["loading", "mutating"].includes(view.phase);
    if (!currentWindow(win) || !win.taskList) return;
    win.taskList.replaceChildren();
    win.taskList.setAttribute("aria-busy", String(busy));
    const filtered = P.filterTasks(view.items, win.view, t);
    win.taskCount.textContent = t(view.phase === "loading" ? "tasksReading" : view.phase === "mutating" ? "tasksMutating" : view.pageNumber ? "taskPageCount" : "taskPageStart", { page: view.pageNumber, count: view.items.length, matches: filtered.length });
    win.taskReload.disabled = busy || view.phase === "closed";
    if (win.taskCreate) win.taskCreate.disabled = !canWrite() || busy || view.phase === "closed";
    win.taskNext.disabled = busy || !view.hasNext || view.requiresReload || view.phase !== "ready";
    win.taskFailure.hidden = !view.error;
    win.taskFailure.textContent = view.error ? (["expired", "replay", "denied", "staleState"].includes(view.error) ? t("taskPageLost") : errorMessage({ code: view.error })) + (view.items.length ? " " + t("taskStaleHint") : "") : "";
    if (win.taskEnd) { win.taskEnd.hidden = view.phase !== "ready" || view.hasNext; win.taskEnd.textContent = t("taskPageEnd"); }
    if (!filtered.length) {
      if (!busy && view.phase === "ready") win.taskList.append(emptyState("tasks", view.items.length ? "taskNoMatches" : "taskEmptyPage", view.items.length ? "taskNoMatchHint" : "taskEmptyHint"));
      return;
    }
    for (const job of filtered) {
      const row = el("article", "task-row " + job.state); row.dataset.jobId = job.id; row.dataset.state = job.state;
      const mark = el("span", "mini-task-icon"); mark.append(icon(job.kind === "fixtureHash" ? "file" : "tasks"));
      const copy = el("div", "task-copy"), top = el("div", "task-top"); top.append(el("h3", "", jobName(job)), statePill(job));
      const meta = el("div", "task-meta"); meta.append(el("span", "", t("attempts", { count: job.attempts, max: job.maxAttempts })), el("span", "", t("stepProgress", { count: progress(job) })));
      const bar = el("div", "progress-track"), fill = el("span"); fill.style.width = progress(job) * 50 + "%"; bar.append(fill); bar.setAttribute("role", "progressbar"); bar.setAttribute("aria-label", jobName(job) + " / " + t("progress")); bar.setAttribute("aria-valuemin", "0"); bar.setAttribute("aria-valuemax", "2"); bar.setAttribute("aria-valuenow", String(progress(job)));
      copy.append(top, meta, bar);
      if (job.lastError) copy.append(el("p", "task-error", errorMessage({ code: job.lastError })));
      const actions = el("div", "task-actions"); actions.append(button(t("details"), "text-button", () => taskDetail(job)));
      if (!["failed", "completed", "cancelled"].includes(job.state)) {
        const cancel = button(t("cancelTask"), "secondary-button", () => cancelTaskModal(job, win)); cancel.dataset.cancelJob = job.id; cancel.disabled = !canWrite() || view.phase !== "ready"; if (!canWrite()) cancel.title = t("readOnlyAction"); actions.append(cancel);
      }
      row.append(mark, copy, actions); win.taskList.append(row);
    }
  }
  function emptyState(name, title, hint) {
    const node = el("div", "empty-state"); node.append(icon(name), el("h3", "", t(title))); if (hint) node.append(el("p", "", t(hint))); return node;
  }
  function taskDetail(job) {
    const content = el("div"), list = el("dl", "detail-grid");
    for (const [key, value] of [["status", t(job.state)], ["progress", t("stepProgress", { count: progress(job) })], ["checkpoint", t(job.steps === 2 ? "stepComplete" : job.steps === 1 ? "prepared" : "notStarted")], ["actions", t("attempts", { count: job.attempts, max: job.maxAttempts })]]) list.append(el("dt", "", t(key)), el("dd", "", value));
    content.append(list); if (job.lastError) content.append(el("p", "", errorMessage({ code: job.lastError })));
    showModal(jobName(job), content, [{ key: "done", style: "secondary-button", action: closeModal }]);
  }
  function cancelTaskModal(job, win) {
    const epoch = state.epoch, content = el("div"); content.append(el("p", "", t("cancelHint")));
    showModal(t("cancelQuestion", { name: jobName(job) }), content, [
      { key: "back", style: "secondary-button", action: closeModal },
      { key: "cancelConfirm", style: "danger-button", action: async ({ isCurrent }) => {
        const pending = win.pager.cancelJob(job.id); renderTaskRows(win);
        try { await pending; } finally { if (epoch === state.epoch && currentWindow(win)) renderTaskRows(win); }
        if (epoch !== state.epoch || !currentWindow(win) || !isCurrent()) return;
        const cancelled = win.pager.snapshot().items.find(item => item.id === job.id)?.state === "cancelled";
        closeModal();
        try { await refreshData(); } catch { if (epoch === state.epoch && currentWindow(win)) toast(t("taskRefreshFailed")); return; }
        if (epoch === state.epoch && currentWindow(win)) { toast(t(cancelled ? "cancelledToast" : "taskStateRefreshed")); focusActiveHeading(); }
      }}
    ]);
  }
  function createTaskModal(win) {
    const content = el("div"), hint = el("p", "", t("newTaskHint")), label = el("label", "", t("taskValue")), input = el("input");
    input.id = "new-task-value"; input.type = "text"; input.maxLength = 80; input.placeholder = t("taskPlaceholder"); input.value = t("jobNew"); label.htmlFor = input.id;
    content.append(hint, label, input);
    const epoch = state.epoch, source = state.taskSource, id = "preview-" + crypto.randomUUID(); let intent;
    showModal(t("newTask"), content, [
      { key: "back", style: "secondary-button", action: closeModal },
      { key: "addToQueue", style: "primary-button", action: async ({ isCurrent }) => {
        if (!intent) {
          const value = input.value.trim();
          if (!value || value.length > 80 || value.includes("\0")) throw new M.ServiceError("invalidInput");
          intent = Object.freeze({ id, key: id, value }); input.readOnly = true;
        }
        await source.submitLabelJob(intent); if (epoch !== state.epoch || !currentWindow(win) || !isCurrent()) return;
        closeModal();
        const refreshed = await moveTaskPage(win, "reload");
        if (epoch !== state.epoch || !currentWindow(win)) return;
        try { await refreshData(); } catch { if (epoch === state.epoch && currentWindow(win)) toast(t("taskRefreshFailed")); return; }
        if (epoch === state.epoch && currentWindow(win)) { toast(t(refreshed ? "taskCreated" : "taskRefreshFailed")); focusActiveHeading(); }
      }}
    ]); input.focus(); input.select();
  }
  function renderFiles(win) {
    win.content.replaceChildren(); win.content.classList.add("file-browser-window");
    win.previewRequest = (win.previewRequest || 0) + 1;
    if (!win.filePager) { win.filePager = B.createFileBrowser({ source: state.directorySource }); win.libraryPhase = "idle"; win.libraries = []; }
    if (!win.fileOperation && state.directorySource.fileOperations) win.fileOperation = O.createController(state.directorySource.fileOperations);
    const view = win.filePager.snapshot(), shell = el("div", "file-browser-shell"), side = el("aside", "file-browser-sidebar");
    side.setAttribute("aria-label", t("fileLocations")); side.append(el("h2", "", t("fileLocations")));
    win.libraryReload = button(t("reloadLibraries"), "text-button", () => loadFileLibraries(win), "refresh"); side.append(win.libraryReload);
    win.fileLocations = el("nav"); win.fileLocations.setAttribute("aria-label", t("fileLibrary")); side.append(win.fileLocations);
    win.fileFolders = el("nav"); win.fileFolders.setAttribute("aria-label", t("fileLoadedFolders")); side.append(el("h3", "", t("fileLoadedFolders")), win.fileFolders);
    const main = el("section", "file-browser-main"), header = el("header", "file-browser-header");
    const title = el("div", "file-browser-title"); title.append(el("h1", "", t("files")), el("span", "pill", t(canWrite() ? "demoShort" : "recover"))); header.append(title, el("p", "file-demo-note", t("demoHint")));
    const compactLocation = el("div", "file-compact-location"), compactLabel = el("label", "", t("fileLibrary")); compactLabel.htmlFor = "file-library";
    win.librarySelect = el("select"); win.librarySelect.id = compactLabel.htmlFor; win.librarySelect.addEventListener("change", event => { void moveFilePage(win, "open", { libraryID: event.target.value }); });
    win.libraryReloadCompact = namedIconButton("reloadLibraries", "refresh", () => loadFileLibraries(win));
    compactLocation.append(compactLabel, win.librarySelect, win.libraryReloadCompact); header.append(compactLocation);
    const navigation = el("div", "file-navigation");
    win.fileBack = namedIconButton("fileBack", "back", () => moveFilePage(win, "back"));
    win.fileForward = namedIconButton("fileForward", "arrow", () => moveFilePage(win, "forward"));
    win.fileUp = namedIconButton("fileUp", "arrow", () => moveFilePage(win, "up")); win.fileUp.classList.add("file-up");
    win.fileReload = namedIconButton("reloadFiles", "refresh", () => moveFilePage(win, "reload")); win.fileReload.dataset.fileReload = "";
    navigation.append(win.fileBack, win.fileForward, win.fileUp, win.fileReload);
    win.fileCrumbs = el("nav", "file-breadcrumbs"); win.fileCrumbs.setAttribute("aria-label", t("fileCurrentPath")); navigation.append(win.fileCrumbs); header.append(navigation);
    const toolbar = el("div", "files-toolbar file-browser-tools");
    const search = searchField("fileSearchLoaded", view.settings.search, event => configureFiles(win, { search: event.target.value }));
    win.fileSearch = $("input", search); win.fileSearch.maxLength = 128; win.fileSearch.dataset.fileSearch = "";
    const filter = selectField("file-type", "fileType", [["all", "allFiles"], ["directory", "foldersOnly"], ["file", "filesOnly"]], view.settings.filter, event => configureFiles(win, { filter: event.target.value }));
    win.fileFilter = $("select", filter);
    const sort = selectField("file-sort", "fileSort", [["name", "fileSortName"], ["size", "fileSortSize"], ["type", "fileSortType"], ["modified", "fileSortModified"]], view.settings.sort, event => configureFiles(win, { sort: event.target.value }));
    win.fileSort = $("select", sort);
    win.fileDirection = button(t(view.settings.direction === "ascending" ? "fileAscending" : "fileDescending"), "text-button", () => configureFiles(win, { direction: win.filePager.snapshot().settings.direction === "ascending" ? "descending" : "ascending" }));
    const grid = namedIconButton("fileView", win.view.grid ? "list" : "apps", () => { win.view.grid = !win.view.grid; renderFiles(win); }); grid.setAttribute("aria-pressed", String(win.view.grid));
    toolbar.append(search, filter, sort, win.fileDirection, grid); header.append(toolbar);
    const operations = el("div", "file-operation-tools");
    win.fileCreate = button(t("fileCreateDirectory"), "secondary-button", () => fileOperationDraft(win, "createDirectory"), "plus"); win.fileCreate.dataset.fileCreate = "";
    win.fileRename = button(t("fileRename"), "secondary-button", () => fileOperationDraft(win, "rename"), "file"); win.fileRename.dataset.fileRename = "";
    win.fileOperationPermission = el("span", "file-operation-hint"); operations.append(win.fileCreate, win.fileRename, win.fileOperationPermission); header.append(operations);
    win.fileOperationNotice = el("div", "file-operation-notice"); win.fileOperationNotice.setAttribute("role", "status"); win.fileOperationNotice.setAttribute("aria-live", "polite"); header.append(win.fileOperationNotice);
    header.append(el("p", "file-scope", t("fileLoadedScope")));
    win.fileFailure = el("p", "readonly-note"); win.fileFailure.setAttribute("role", "alert"); header.append(win.fileFailure); main.append(header);
    const workspace = el("div", "file-workspace"), listing = el("div", "file-listing");
    const columns = el("div", "file-columns"); columns.hidden = win.view.grid; columns.setAttribute("aria-hidden", "true");
    for (const key of ["fileSortName", "fileSortSize", "fileSortModified"]) columns.append(el("span", "", t(key))); listing.append(columns);
    win.fileList = el("div", "file-list" + (win.view.grid ? " grid" : "")); win.fileList.setAttribute("role", "listbox"); win.fileList.setAttribute("aria-label", t("files")); win.fileList.setAttribute("aria-multiselectable", "true"); win.fileList.tabIndex = 0;
    win.fileList.addEventListener("keydown", event => fileListKeydown(win, event)); listing.append(win.fileList);
    win.fileDetails = el("aside", "file-details"); win.fileDetails.setAttribute("aria-label", t("fileDetails")); workspace.append(listing, win.fileDetails); main.append(workspace);
    const footer = el("footer", "file-statusbar"); win.fileCount = el("p", "toolbar-count"); win.fileCount.setAttribute("role", "status"); win.fileCount.setAttribute("aria-live", "polite"); win.fileCount.tabIndex = -1;
    win.fileNext = button(t("fileLoadMore"), "secondary-button", () => moveFilePage(win, "next"), "arrow"); win.fileNext.dataset.fileNext = "";
    win.fileEnd = el("p", "file-end"); footer.append(win.fileCount, win.fileNext, win.fileEnd); main.append(footer);
    win.librarySummary = el("p", "file-library-summary"); win.librarySummary.setAttribute("role", "status"); side.append(win.librarySummary);
    shell.append(side, main); win.content.append(shell);
    shell.addEventListener("keydown", event => {
      if (!event.altKey || event.ctrlKey || event.metaKey || event.target.closest("input,select")) return;
      const action = { ArrowLeft: "back", ArrowRight: "forward", ArrowUp: "up" }[event.key], current = win.filePager.snapshot();
      if (!action) return; event.preventDefault(); event.stopPropagation();
      if (current.phase !== "loading" && (action === "back" ? current.canGoBack : action === "forward" ? current.canGoForward : current.canGoUp)) void moveFilePage(win, action);
    });
    renderFileRows(win);
    if (win.libraryPhase === "idle") void loadFileLibraries(win);
  }
  function fileLibraryName(id) { return state.directorySource.context.source === "fixture" && ["shared", "personal"].includes(id) ? t(id === "shared" ? "fileSharedLocation" : "filePersonalLocation") : id; }
  function configureFiles(win, settings) {
    win.previewRequest = (win.previewRequest || 0) + 1;
    if (win.fileModal && state.modal === win.fileModal) closeModal(false);
    win.filePager.configure(settings); renderFileRows(win);
  }
  function fileError(error) {
    const keys = { staleState: "fileDirectoryChanged", expired: "fileContinuationLost", replay: "fileContinuationLost", denied: "fileAccessDenied", missingVolume: "fileVolumeMissing", budgetExceeded: "fileBudgetExceeded", unavailable: "fileUnavailable", timedOut: "fileUnavailable", cancelled: "fileUnavailable" };
    return keys[error] ? t(keys[error]) : errorMessage({ code: error }) + " " + t("fileReloadRequired");
  }
  async function loadFileLibraries(win) {
    if (!currentWindow(win) || win.libraryPhase === "loading") return;
    const epoch = state.epoch, serial = win.libraryRequest = (win.libraryRequest || 0) + 1, source = state.directorySource;
    win.libraryPhase = "loading"; win.libraryError = null; renderFileRows(win);
    try {
      const libraries = await source.libraries();
      if (epoch !== state.epoch || !currentWindow(win) || serial !== win.libraryRequest) return;
      const changed = JSON.stringify(win.libraries.map(x => x.libraryID).sort()) !== JSON.stringify(libraries.map(x => x.libraryID).sort());
      win.libraries = libraries; win.libraryPhase = "ready";
      if (changed) {
        win.filePager.dispose(); win.filePager = B.createFileBrowser({ source }); win.previewRequest = (win.previewRequest || 0) + 1;
        win.fileOperation?.dispose(); win.fileOperation = source.fileOperations ? O.createController(source.fileOperations) : null;
        if (win.fileModal && state.modal === win.fileModal) closeModal(false);
      }
      const current = win.filePager.snapshot().libraryID;
      if (!libraries.some(item => item.libraryID === current)) {
        if (libraries.length) await moveFilePage(win, "open", { libraryID: libraries[0].libraryID }, false);
        else { win.filePager.dispose(); win.filePager = B.createFileBrowser({ source }); }
      }
    } catch (error) {
      if (epoch !== state.epoch || !currentWindow(win) || serial !== win.libraryRequest) return;
      win.libraryPhase = "error"; win.libraryError = error.code || "unavailable";
    }
    if (epoch === state.epoch && currentWindow(win)) renderFileRows(win);
  }
  async function moveFilePage(win, direction, target, focus = true) {
    if (!currentWindow(win) || win.libraryPhase !== "ready") return;
    const epoch = state.epoch, pager = win.filePager;
    win.previewRequest = (win.previewRequest || 0) + 1;
    if (win.fileModal && state.modal === win.fileModal) closeModal(false);
    const pending = direction === "open" ? pager.open(target) : pager[direction](); renderFileRows(win);
    try { await pending; } catch { /* The controller exposes only a fixed error code and retains its labelled last page. */ }
    if (epoch !== state.epoch || !currentWindow(win) || pager !== win.filePager) return;
    renderFileRows(win); if (focus && !state.modal) win.fileCount.focus();
  }
  async function previewFile(win, file) {
    if (!currentWindow(win) || win.libraryPhase !== "ready") return;
    focusWindow(win.id);
    const epoch = state.epoch, pager = win.filePager, serial = win.previewRequest = (win.previewRequest || 0) + 1, modalEpoch = state.modalEpoch;
    const pending = pager.preview(file.relativePath); renderFileRows(win);
    let data;
    try { data = await pending; } catch { /* The current page shows the failure; no raw diagnostics enter the DOM. */ }
    if (epoch !== state.epoch || !currentWindow(win) || pager !== win.filePager || serial !== win.previewRequest) return;
    renderFileRows(win); if (!data || state.modalEpoch !== modalEpoch || state.active !== win.id) return;
    focusFileRow(win, file.relativePath);
    const content = el("div"); content.append(el("p", "", t("filePreviewHint")), el("div", "preview-content", data.text));
    showModal(file.name, content, [{ key: "done", style: "secondary-button", action: closeModal }]); win.fileModal = state.modal;
  }
  function renderFileRows(win) {
    if (!currentWindow(win) || !win.fileList) return;
    if (win.filePager.snapshot().settings.locale !== prefs.locale) {
      try { win.filePager.configure({ locale: prefs.locale }); } catch { /* A closed source still renders its labelled stale view. */ }
    }
    const view = win.filePager.snapshot(), busy = view.phase === "loading", available = win.libraryPhase === "ready";
    const actionable = available && view.phase === "ready" && !view.requiresReload, visible = view.visibleItems;
    win.fileSearch.value = view.settings.search; win.fileFilter.value = view.settings.filter; win.fileSort.value = view.settings.sort;
    win.fileDirection.textContent = t(view.settings.direction === "ascending" ? "fileAscending" : "fileDescending");
    win.libraryReload.disabled = win.libraryPhase === "loading";
    win.libraryReloadCompact.disabled = win.libraryPhase === "loading";
    win.librarySelect.replaceChildren();
    for (const library of win.libraries) { const option = el("option", "", fileLibraryName(library.libraryID)); option.value = library.libraryID; win.librarySelect.append(option); }
    win.librarySelect.value = view.libraryID || ""; win.librarySelect.disabled = !available || busy || !win.libraries.length;
    win.fileLocations.replaceChildren(); win.fileFolders.replaceChildren();
    for (const library of win.libraries) {
      const control = button(fileLibraryName(library.libraryID), view.libraryID === library.libraryID ? "selected" : "", () => moveFilePage(win, "open", { libraryID: library.libraryID }), "storage");
      control.disabled = !available || busy; if (view.libraryID === library.libraryID) control.setAttribute("aria-current", "location"); win.fileLocations.append(control);
    }
    for (const file of view.items.filter(item => item.kind === "directory")) {
      const control = button(file.name, "", () => moveFilePage(win, "open", { libraryID: view.libraryID, relativePath: file.relativePath }), "folder"); control.disabled = !actionable; win.fileFolders.append(control);
    }
    if (!win.fileFolders.childElementCount) win.fileFolders.append(el("p", "", t("fileNoLoadedFolders")));
    const selected = win.libraries.find(item => item.libraryID === view.libraryID);
    win.librarySummary.textContent = win.libraryPhase === "loading" ? t("librariesReading") : t("fileLibraryCount", { count: win.libraries.length }) + " " + (selected?.estimatedBytes === null || !selected ? t("fileEstimateUnavailable") : t("fileLibraryEstimate", { bytes: new Intl.NumberFormat(prefs.locale).format(selected.estimatedBytes) }));
    win.fileCrumbs.replaceChildren();
    if (view.libraryID) {
      win.fileCrumbs.append(button(fileLibraryName(view.libraryID), "", () => moveFilePage(win, "open", { libraryID: view.libraryID })));
      const parts = view.relativePath ? view.relativePath.split("/") : [];
      parts.forEach((part, index) => { win.fileCrumbs.append(icon("arrow"), button(part, "", () => moveFilePage(win, "open", { libraryID: view.libraryID, relativePath: parts.slice(0, index + 1).join("/") }))); });
    }
    for (const control of win.fileCrumbs.querySelectorAll("button")) control.disabled = !available || busy;
    win.fileCount.textContent = t(busy ? "filesReading" : view.previewPhase === "loading" ? "filePreviewReading" : "fileLoadedCount", { count: view.items.length, matches: visible.length, selected: view.selectedPaths.length });
    win.fileBack.disabled = !available || busy || !view.canGoBack; win.fileForward.disabled = !available || busy || !view.canGoForward; win.fileUp.disabled = !available || busy || !view.canGoUp;
    win.fileReload.disabled = !available || busy || !view.libraryID || view.phase === "closed";
    win.fileNext.disabled = !actionable || !view.hasNext || view.limitReached; win.fileNext.hidden = !view.hasNext;
    const failure = win.libraryError || view.error;
    win.fileFailure.hidden = !failure;
    win.fileFailure.textContent = failure ? (win.libraryError ? t("fileLibrariesFailed") + " " : "") + fileError(failure) + (view.items.length ? " " + t("fileStaleView") : "") : "";
    win.fileEnd.hidden = view.phase !== "ready"; win.fileEnd.textContent = t(view.limitReached ? "fileLoadedLimit" : view.hasNext ? "fileMoreAvailable" : "fileFolderEnd", { count: view.maximumLoaded });
    win.fileList.replaceChildren(); win.fileList.setAttribute("aria-busy", String(busy));
    win.fileList.classList.toggle("stale", !actionable && view.items.length > 0);
    if (busy && view.items.length) win.fileList.append(el("p", "content-note", t("filePreviousWhileLoading")));
    if (!visible.length && !busy && available && view.phase === "ready") win.fileList.append(emptyState("files", view.items.length ? "fileNoMatches" : "emptyFolder", view.items.length ? "fileNoMatchHint" : "fileEmptyHint"));
    if (available && !win.libraries.length) win.fileList.append(emptyState("files", "fileNoLibraries"));
    for (const file of visible) {
      const row = el("div", "file-row"); row.setAttribute("role", "option"); row.setAttribute("aria-disabled", String(!actionable)); row.dataset.filePath = file.relativePath;
      row.addEventListener("click", event => { if (!actionable) return; win.filePager.select(file.relativePath, { toggle: event.metaKey || event.ctrlKey, range: event.shiftKey }); updateFileSelection(win); row.focus(); });
      row.addEventListener("dblclick", () => { if (actionable) activateFile(win, file); });
      const name = el("span"); name.append(icon(file.kind === "directory" ? "folder" : "file"), el("span", "", file.name));
      row.append(name, el("span", "", file.bytes === null ? t("folder") : t("fileBytes", { bytes: new Intl.NumberFormat(prefs.locale).format(file.bytes) })), el("span", "", file.modifiedAt === null ? t("fileTimeUnavailable") : new Intl.DateTimeFormat(prefs.locale, { dateStyle: "medium", timeStyle: "short" }).format(new Date(file.modifiedAt))));
      win.fileList.append(row);
    }
    updateFileSelection(win);
  }
  function focusFileRow(win, path) { [...win.fileList.querySelectorAll("[data-file-path]")].find(row => row.dataset.filePath === path)?.focus(); }
  function updateFileSelection(win) {
    const view = win.filePager.snapshot(), rows = [...win.fileList.querySelectorAll("[data-file-path]")], actionable = win.libraryPhase === "ready" && view.phase === "ready" && !view.requiresReload;
    const focusPath = view.activePath || rows[0]?.dataset.filePath;
    for (const row of rows) { const selected = view.selectedPaths.includes(row.dataset.filePath); row.classList.toggle("selected", selected); row.setAttribute("aria-selected", String(selected)); row.tabIndex = actionable && row.dataset.filePath === focusPath ? 0 : -1; }
    win.fileList.tabIndex = actionable && rows.length ? -1 : 0;
    if (view.phase !== "loading" && view.previewPhase !== "loading") win.fileCount.textContent = t("fileLoadedCount", { count: view.items.length, matches: view.visibleItems.length, selected: view.selectedPaths.length });
    renderFileDetails(win, view, actionable);
    renderFileOperationControls(win, view, actionable);
  }
  function renderFileOperationControls(win, view, actionable) {
    const operation = win.fileOperation?.snapshot(), busy = operation && ["previewing", "committing", "checking"].includes(operation.phase);
    const allowed = actionable && win.fileOperation?.canWrite && !busy && operation?.phase !== "uncertain";
    win.fileCreate.disabled = !allowed; win.fileRename.disabled = !allowed || view.selectedItems.length !== 1;
    win.fileOperationPermission.textContent = win.fileOperation?.canWrite ? t("fileOperationShortHint") : t("fileOperationReadOnly");
    win.fileOperationNotice.replaceChildren();
    const phase = operation?.phase; win.fileOperationNotice.hidden = !["committing", "checking", "completed", "failed", "uncertain"].includes(phase);
    if (win.fileOperationNotice.hidden) return;
    const key = { committing: "fileOperationApplying", checking: "fileOperationChecking", completed: "fileOperationCompleted", failed: "fileOperationFailed", uncertain: "fileOperationUncertain" }[phase];
    win.fileOperationNotice.append(el("span", "", t(key)));
    if (["completed", "failed", "uncertain"].includes(phase)) win.fileOperationNotice.append(button(t("fileOperationViewResult"), "text-button", () => fileOperationResult(win)));
  }
  function fileOperationDraft(win, kind, previousName) {
    if (!currentWindow(win) || !win.fileOperation?.canWrite) return;
    const view = win.filePager.snapshot(), operation = win.fileOperation.snapshot();
    if (win.libraryPhase !== "ready" || view.phase !== "ready" || view.requiresReload || ["previewing", "committing", "checking", "uncertain"].includes(operation.phase)) return;
    const selected = view.selectedItems[0]; if (kind === "rename" && view.selectedItems.length !== 1) return;
    const captured = Object.freeze({ libraryID: view.libraryID, parentPath: view.relativePath, kind, ...(kind === "rename" ? { sourceName: selected.name } : {}) });
    fileOperationInput(win, captured, previousName ?? (kind === "rename" ? selected.name : t("fileNewDirectoryName")));
  }
  function fileOperationInput(win, captured, name) {
    const content = el("div"), label = el("label", "", t("fileOperationName")), input = el("input"); label.htmlFor = "file-operation-name"; input.id = label.htmlFor; input.value = name; input.maxLength = 255;
    const path = fileLibraryName(captured.libraryID) + (captured.parentPath ? "/" + captured.parentPath : "");
    content.append(el("p", "", path), label, input, el("p", "", t("fileOperationPreviewHint")));
    const epoch = state.epoch, controller = win.fileOperation;
    showModal(t(captured.kind === "createDirectory" ? "fileCreateDirectory" : "fileRename"), content, [
      { key: "cancel", style: "secondary-button", action: closeModal },
      { key: "fileOperationPreview", style: "primary-button", action: async ({ isCurrent }) => {
        const request = O.intent({ ...captured, name: input.value }, true); input.readOnly = true;
        const pending = controller.prepare(request); renderFileRows(win);
        try { await pending; } finally { input.readOnly = false; if (epoch === state.epoch && currentWindow(win) && controller === win.fileOperation) renderFileRows(win); }
        if (epoch !== state.epoch || !currentWindow(win) || controller !== win.fileOperation || !isCurrent()) return;
        fileOperationPreview(win, controller.snapshot().preview);
      }}
    ]); win.fileModal = state.modal; input.focus(); input.select();
  }
  function fileOperationPreview(win, preview) {
    if (!preview) return;
    const content = el("div"), intent = preview.intent, details = el("dl", "detail-grid");
    for (const [key, value] of [["fileCurrentPath", fileLibraryName(intent.libraryID) + (intent.parentPath ? "/" + intent.parentPath : "")], ...(intent.sourceName === null ? [] : [["fileOperationOriginalName", intent.sourceName]]), ["fileOperationName", intent.name]]) details.append(el("dt", "", t(key)), el("dd", "", value));
    content.append(el("p", "", t(preview.state === "ready" ? "fileOperationConfirmHint" : preview.state === "conflict" ? "fileOperationConflict" : "fileOperationUnchanged")), details);
    const actions = [
      { key: "cancel", style: "secondary-button", action: closeModal },
      { key: "fileOperationEditName", style: "secondary-button", action: () => fileOperationInput(win, { libraryID: intent.libraryID, parentPath: intent.parentPath, kind: intent.kind, ...(intent.sourceName === null ? {} : { sourceName: intent.sourceName }) }, intent.name) }
    ];
    if (preview.state === "ready") actions.push({ key: "fileOperationApply", style: "primary-button", action: current => applyFileOperation(win, current) });
    showModal(t("fileOperationPreview"), content, actions); win.fileModal = state.modal;
  }
  async function applyFileOperation(win, { isCurrent }) {
    const epoch = state.epoch, controller = win.fileOperation, preview = controller.snapshot().preview, pager = win.filePager, location = pager.snapshot();
    if (!preview || location.libraryID !== preview.intent.libraryID || location.relativePath !== preview.intent.parentPath) throw new M.ServiceError("staleState");
    const pending = controller.commit(); renderFileRows(win);
    try { await pending; } catch { /* A fixed error remains uncertain until explicitly observed. */ }
    if (epoch !== state.epoch || !currentWindow(win) || controller !== win.fileOperation) return;
    renderFileRows(win); const outcome = controller.snapshot();
    if (outcome.phase === "completed") {
      if (isCurrent()) closeModal(false);
      const current = pager.snapshot();
      if (pager === win.filePager && current.libraryID === preview.intent.libraryID && current.relativePath === preview.intent.parentPath && current.phase !== "loading") await moveFilePage(win, "reload", undefined, false);
      if (epoch === state.epoch && currentWindow(win)) toast(t(win.filePager.snapshot().phase === "ready" ? "fileOperationCompleted" : "fileOperationReloadFailed"));
    } else if (isCurrent()) fileOperationResult(win);
  }
  function fileOperationResult(win) {
    const controller = win.fileOperation, view = controller?.snapshot(); if (!view) return;
    const content = el("div"), intent = view.preview?.intent;
    content.append(el("p", "", t(view.phase === "completed" ? "fileOperationCompleted" : view.phase === "failed" ? "fileOperationFailed" : "fileOperationUncertain")));
    if (intent) content.append(el("p", "", fileLibraryName(intent.libraryID) + "/" + (intent.parentPath ? intent.parentPath + "/" : "") + intent.name));
    if (view.error) content.append(el("p", "", view.error === "expired" ? t("fileOperationExpired") : view.error === "collision" ? t("fileOperationConflict") : fileError(view.error)));
    if (view.phase === "uncertain") content.append(el("p", "", t("fileOperationNoRepeat")));
    const actions = [{ key: "done", style: "secondary-button", action: closeModal }];
    if (view.phase === "uncertain") actions.unshift({ key: "fileOperationCheck", style: "primary-button", action: async ({ isCurrent }) => {
      const epoch = state.epoch, pending = controller.check(); renderFileRows(win);
      try { await pending; } finally { if (epoch === state.epoch && currentWindow(win) && controller === win.fileOperation) renderFileRows(win); }
      if (epoch !== state.epoch || !currentWindow(win) || controller !== win.fileOperation || !isCurrent()) return;
      const observed = controller.snapshot(), location = win.filePager.snapshot(), intent = observed.preview?.intent;
      if (observed.phase === "completed" && intent && location.libraryID === intent.libraryID && location.relativePath === intent.parentPath && location.phase !== "loading") await moveFilePage(win, "reload", undefined, false);
      if (epoch !== state.epoch || !currentWindow(win) || controller !== win.fileOperation || !isCurrent()) return;
      fileOperationResult(win);
    }});
    showModal(t("fileOperationViewResult"), content, actions); win.fileModal = state.modal;
  }
  function renderFileDetails(win, view, actionable) {
    const pane = win.fileDetails; pane.replaceChildren(); pane.append(el("h2", "", t("fileDetails")));
    const files = view.selectedItems;
    if (!files.length) { pane.append(icon("files"), el("p", "", t("fileSelectHint")), el("p", "file-keyboard-hint", t("fileKeyboardHint"))); return; }
    if (files.length > 1) {
      pane.append(icon("files"), el("h3", "", t("fileSelectionCount", { count: files.length })), el("p", "", t("fileSelectionBytes", { bytes: new Intl.NumberFormat(prefs.locale).format(files.reduce((sum, file) => sum + BigInt(file.bytes || 0), 0n)) }))); return;
    }
    const file = files[0]; pane.append(icon(file.kind === "directory" ? "folder" : "file"), el("h3", "", file.name));
    const details = el("dl");
    for (const [key, value] of [["fileSortType", file.kind === "directory" ? t("folder") : file.name.includes(".") ? file.name.split(".").at(-1).toUpperCase() : t("fileGenericType")], ["fileCurrentPath", fileLibraryName(view.libraryID) + "/" + file.relativePath], ["fileSortSize", file.bytes === null ? t("fileSizeUnknown") : t("fileBytes", { bytes: new Intl.NumberFormat(prefs.locale).format(file.bytes) })], ["fileSortModified", file.modifiedAt === null ? t("fileTimeUnavailable") : new Intl.DateTimeFormat(prefs.locale, { dateStyle: "medium", timeStyle: "short" }).format(new Date(file.modifiedAt))]]) details.append(el("dt", "", t(key)), el("dd", "", value));
    pane.append(details);
    const open = button(t(file.kind === "directory" ? "fileOpenFolder" : "fileOpenPreview"), "secondary-button", () => activateFile(win, file), file.kind === "directory" ? "folder" : "file"); open.disabled = !actionable || view.previewPhase === "loading" || file.kind === "file" && !file.canPreview; pane.append(open);
    if (file.kind === "file" && !file.canPreview) pane.append(el("p", "", t("filePreviewUnsupported")));
  }
  function activateFile(win, file) {
    const view = win.filePager.snapshot();
    if (file.kind === "directory") void moveFilePage(win, "open", { libraryID: view.libraryID, relativePath: file.relativePath });
    else if (file.canPreview) void previewFile(win, file);
  }
  function fileListKeydown(win, event) {
    if (event.altKey) return;
    const view = win.filePager.snapshot(); if (win.libraryPhase !== "ready" || view.phase !== "ready" || view.requiresReload) return;
    const paths = view.visibleItems.map(file => file.relativePath), current = event.target.closest("[data-file-path]")?.dataset.filePath || view.activePath;
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "a") { event.preventDefault(); event.stopPropagation(); win.filePager.selectAll(); updateFileSelection(win); focusFileRow(win, win.filePager.snapshot().activePath); return; }
    if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); win.filePager.clearSelection(); updateFileSelection(win); return; }
    if (["ArrowDown", "ArrowRight", "ArrowUp", "ArrowLeft", "Home", "End"].includes(event.key) && paths.length) {
      event.preventDefault(); event.stopPropagation(); const index = Math.max(0, paths.indexOf(current));
      const next = event.key === "Home" ? 0 : event.key === "End" ? paths.length - 1 : Math.max(0, Math.min(paths.length - 1, index + (["ArrowDown", "ArrowRight"].includes(event.key) ? 1 : -1)));
      win.filePager.select(paths[next], { range: event.shiftKey }); updateFileSelection(win); focusFileRow(win, paths[next]); return;
    }
    if (!current) return;
    if (event.key === " ") { event.preventDefault(); event.stopPropagation(); win.filePager.select(current, { toggle: event.metaKey || event.ctrlKey, range: event.shiftKey }); updateFileSelection(win); }
    if (event.key === "Enter") { event.preventDefault(); event.stopPropagation(); const file = view.visibleItems.find(item => item.relativePath === current); if (file) activateFile(win, file); }
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
    const modalState = { element: modal, previousFocus }, isCurrent = () => state.modal === modalState;
    heading.id = "modal-title"; modal.setAttribute("role", "dialog"); modal.setAttribute("aria-modal", "true"); modal.setAttribute("aria-labelledby", heading.id);
    head.append(heading, namedIconButton("close", "close", closeModal)); const footer = el("div", "modal-actions"), failure = el("p", "modal-error"); failure.setAttribute("role", "alert");
    for (const action of actions) {
      const control = button(t(action.key), action.style, async () => {
        if (!isCurrent()) return;
        control.disabled = true;
        try { await action.action({ isCurrent }); } catch (error) { if (isCurrent()) failure.textContent = errorMessage(error); } finally { if (isCurrent()) control.disabled = false; }
      }); control.dataset.modalAction = action.key; footer.append(control);
    }
    modal.append(head, content, failure, footer); backdrop.append(modal); $("#modal-root").replaceChildren(backdrop); state.modal = modalState;
    backdrop.addEventListener("pointerdown", event => { if (event.target === backdrop) closeModal(); });
    $("input,button,select", modal)?.focus();
  }
  function closeModal(restoreFocus = true) {
    const previous = state.modal?.previousFocus; $("#modal-root").replaceChildren(); state.modal = null; state.modalEpoch++;
    if (restoreFocus !== false && previous?.isConnected) previous.focus();
  }
  function focusActiveHeading() { if (state.modal) return; const win = state.windows.get(state.active); const heading = win && $("h1", win.content); if (heading) { heading.tabIndex = -1; heading.focus(); } }

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
    const view = state.notifications?.snapshot(), items = view?.items || [], count = items.length;
    const busy = ["polling", "acknowledging"].includes(view?.phase), blocked = !view || view.unavailable || !canWrite();
    $("#unread-count").textContent = t("notificationLoaded", { count });
    $("#read-all").textContent = t(view?.ackRetryRequired ? "notificationRetryAck" : "notificationAcknowledge");
    $("#read-all").disabled = blocked || busy || !count;
    $("#refresh-events").disabled = blocked || busy || view.full || view.ackRetryRequired;
    $("#refresh-events").setAttribute("aria-label", t("refresh")); $("#refresh-events").title = t("refresh");
    $("#notification-readonly").hidden = canWrite(); $("#notification-readonly").textContent = t("notificationRecovery");
    $("#notification-hint").textContent = t("notificationBoundedHint", { capacity: view?.capacity || 100 });
    const status = $("#notification-status"); status.hidden = !busy && !view?.error && !view?.full;
    status.textContent = view?.error ? t(view.unavailable ? "notificationDisconnected" : view.ackRetryRequired ? "notificationAckUncertain" : "notificationPollFailed") + " " + errorMessage({ code: view.error }) : busy ? t(view.phase === "polling" ? "notificationLoading" : "notificationConfirming") : view?.full ? t("notificationFull") : "";
    $("#notification-button").setAttribute("aria-label", t("notifications") + (count ? " · " + t("notificationLoaded", { count }) : ""));
    $(".notification-dot").hidden = !count;
    const list = $("#notification-list"); list.replaceChildren();
    const tasks = [...(state.windows.get("tasks")?.pager?.snapshot().items || []), ...state.previewJobs];
    for (const event of items) {
      const row = el("article", "notification-item " + event.state + " unread"); row.dataset.eventSequence = String(event.sequence);
      row.append(icon(event.state === "failed" ? "error" : event.state === "waiting_for_volume" ? "storage" : event.type === "cancelled" ? "close" : event.state === "completed" ? "check" : "tasks"));
      const copy = el("div");
      copy.append(el("strong", "", eventTitle(event)), el("p", "", N.notificationTaskName(event, tasks, t))); row.append(copy); list.append(row);
    }
    if (!items.length) list.append(emptyState("bell", "notificationEmptyLoaded"));
  }
  async function updateNotifications(action) {
    const epoch = state.epoch, notifications = state.notifications;
    if (!notifications) return;
    const pending = notifications[action](); renderNotifications();
    try { await pending; }
    catch (error) { if (epoch === state.epoch && notifications === state.notifications) toast(errorMessage(error)); }
    finally { if (epoch === state.epoch && notifications === state.notifications) renderNotifications(); }
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
    const epoch = state.epoch, serial = ++state.dataRequest, source = state.taskSource;
    const overview = await source.overview(), preview = await source.page({ pageSize: 2 });
    source.discardCursor(preview.nextCursor);
    if (epoch !== state.epoch || serial !== state.dataRequest || source !== state.taskSource) return;
    state.overview = overview; state.previewJobs = preview.tasks;
    const notifications = state.notifications?.snapshot();
    if (canWrite() && notifications && !notifications.full && !notifications.ackRetryRequired && !notifications.unavailable && !["polling", "acknowledging"].includes(notifications.phase)) await updateNotifications("poll");
    if (epoch !== state.epoch || serial !== state.dataRequest || source !== state.taskSource) return;
    refreshViews();
  }
  async function switchScenario(scenario, showPreferences = false) {
    const epoch = ++state.epoch, old = state.session;
    document.body.dataset.ready = "false"; closeModal(false); hidePanels();
    for (const win of state.windows.values()) { win.pager?.dispose(); win.filePager?.dispose(); win.fileOperation?.dispose(); win.element.remove(); }
    const oldSource = state.taskSource; state.notifications?.dispose();
    state.directorySource?.dispose();
    state.windows.clear(); state.active = null; state.previewJobs = []; state.notifications = null; state.overview = null; state.taskSource = null; state.directorySource = null; state.session = null;
    if (oldSource) await oldSource.close(); else await api.endSession(old);
    const session = await api.beginFixtureSession(scenario);
    if (epoch !== state.epoch) { await api.endSession(session); return; }
    const source = await P.createFixtureTaskSource(api, session);
    if (epoch !== state.epoch) { await source.close(); return; }
    let notifications, directorySource;
    try { notifications = await N.createFixtureNotificationView(api, session, { consumerID: "desktop-preview-" + source.context.userID }); directorySource = await F.createFixtureDirectorySource(api, session); }
    catch (error) { notifications?.dispose(); directorySource?.dispose(); await source.close(); throw error; }
    if (epoch !== state.epoch) { notifications.dispose(); directorySource.dispose(); await source.close(); return; }
    state.session = session; state.taskSource = source; state.directorySource = directorySource; state.notifications = notifications; state.scenario = scenario; await refreshData();
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
  $("#refresh-events").addEventListener("click", () => updateNotifications("poll"));
  $("#read-all").addEventListener("click", () => updateNotifications("acknowledge"));
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

(function (root, factory) {
  const api = factory(typeof module === "object" && module.exports ? require("./model.js") : root.MacNASModel);
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.MacNASDownloaders = Object.freeze(api);
})(globalThis, function (M) {
  "use strict";
  const catalog = Object.freeze([
    Object.freeze({ id: "qbittorrent", name: "qBittorrent", version: "5.2.3", descriptionKey: "qbittorrentDescription", bundled: true, removable: true }),
    Object.freeze({ id: "transmission", name: "Transmission", version: "4.1.3", descriptionKey: "transmissionDescription", bundled: true, removable: true })
  ]);
  const check = (value, code) => { if (!value) throw new M.ServiceError(code); };
  // Explicit desktop fixture; native package preparation lives in
  // manage_downloaders.py. This module cannot install or launch macOS apps.
  function createFixturePackageCenter(api) {
    check(api?.source === "fixture" && typeof api.overview === "function" && typeof api.observeFixtureSessionEnd === "function", "unavailable");
    const installed = new Set(catalog.map(item => item.id));
    function forSession(session) {
      let closed = false;
      const stop = api.observeFixtureSessionEnd(session, () => { closed = true; });
      function alive() { check(!closed, "denied"); }
      async function context(write = false) {
        alive(); const value = await api.overview(session);
        alive(); check(value.source === "fixture", "unavailable");
        if (write) {
          check(value.mode === "synthetic_development", "readOnly");
          check(value.role === "administrator", "denied");
        }
      }
      function packageFor(id) { const item = catalog.find(value => value.id === id); check(item, "notFound"); return item; }
      async function change(id, action) {
        packageFor(id); await context(true); alive();
        if (action === "install") installed.add(id); else installed.delete(id);
        return Object.freeze({ id, state: installed.has(id) ? "installed" : "removed", dataPreserved: true });
      }
      return Object.freeze({
        source: "fixture",
        async list() {
          await context(); alive();
          return Object.freeze(catalog.map(item => Object.freeze({ ...item, state: installed.has(item.id) ? "installed" : "removed", autoStart: false, dataPreserved: true })));
        },
        install: id => change(id, "install"),
        uninstall: id => change(id, "uninstall"),
        dispose() { closed = true; stop(); }
      });
    }
    return Object.freeze({ forSession });
  }
  return Object.freeze({ catalog, createFixturePackageCenter });
});

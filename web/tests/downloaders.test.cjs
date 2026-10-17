const test = require('node:test');
const assert = require('node:assert/strict');
const M = require('../dist/model.js');
const D = require('../dist/downloaders.js');
async function fixture(scenario = 'owner') {
  const api = M.createFixtureAdapter(), center = D.createFixturePackageCenter(api), session = await api.beginFixtureSession(scenario);
  return { api, center, session, source: center.forSession(session) };
}
test('both native downloaders are bundled, removable, initially installed and stopped', async () => {
  const { source } = await fixture(); const list = await source.list();
  assert.deepEqual(list.map(x => x.id), ['qbittorrent', 'transmission']);
  assert.ok(list.every(x => x.bundled && x.removable && x.state === 'installed' && !x.autoStart));
});
for (const id of ['qbittorrent', 'transmission']) {
  test(id + ' uninstall keeps data and leaves the other downloader installed', async () => {
    const { source } = await fixture(); assert.deepEqual(await source.uninstall(id), { id, state: 'removed', dataPreserved: true });
    const list = await source.list(); assert.equal(list.find(x => x.id === id).state, 'removed'); assert.equal(list.find(x => x.id !== id).state, 'installed');
  });
  test(id + ' can be reinstalled and repeat actions are idempotent', async () => {
    const { source } = await fixture(); await source.uninstall(id); await source.uninstall(id);
    assert.equal((await source.install(id)).state, 'installed'); assert.equal((await source.install(id)).state, 'installed');
  });
}
test('both packages can be removed together without deleting their catalog entries', async () => {
  const { source } = await fixture(); await source.uninstall('qbittorrent'); await source.uninstall('transmission');
  assert.equal((await source.list()).filter(x => x.state === 'removed').length, 2);
});
test('new sessions do not reinsert a package the user removed', async () => {
  const { api, center, source } = await fixture(); await source.uninstall('transmission'); source.dispose();
  const other = center.forSession(await api.beginFixtureSession('owner'));
  assert.equal((await other.list()).find(x => x.id === 'transmission').state, 'removed');
});
for (const scenario of ['reader', 'recovery']) {
  test(scenario + ' can see packages but cannot install or remove', async () => {
    const { source } = await fixture(scenario); assert.equal((await source.list()).length, 2);
    for (const action of ['install', 'uninstall']) await assert.rejects(source[action]('qbittorrent'), { code: scenario === 'recovery' ? 'readOnly' : 'denied' });
    assert.ok((await source.list()).every(x => x.state === 'installed'));
  });
}
test('unknown packages and path-shaped IDs cannot change the catalog', async () => {
  const { source } = await fixture();
  for (const id of ['../qbittorrent', 'Transmission', '', null, {}, 'arbitrary']) for (const action of ['install', 'uninstall']) await assert.rejects(source[action](id), { code: 'notFound' });
  assert.equal((await source.list()).length, 2);
});
test('revoked sessions cannot mutate or read', async () => {
  const { api, session, source } = await fixture(); await api.endSession(session);
  for (const action of [() => source.list(), () => source.install('qbittorrent'), () => source.uninstall('qbittorrent')]) await assert.rejects(action(), { code: 'denied' });
});
test('disposed views cannot act and do not close another borrowed session', async () => {
  const { api, center, session, source } = await fixture(); const other = center.forSession(session); source.dispose(); source.dispose();
  await assert.rejects(source.uninstall('qbittorrent'), { code: 'denied' }); assert.equal((await other.list()).length, 2); assert.equal((await api.overview(session)).source, 'fixture');
});
test('catalog and returned snapshots cannot mutate installed state', async () => {
  const { source } = await fixture(); const list = await source.list();
  assert.ok(Object.isFrozen(D.catalog) && Object.isFrozen(D.catalog[0]) && Object.isFrozen(list) && Object.isFrozen(list[0]));
  assert.throws(() => list.push({})); assert.equal((await source.list()).length, 2);
});
test('only the explicit fixture API is accepted; no host fallback', () => {
  for (const api of [null, {}, {source:'host'}, {source:'fixture',overview(){}}]) assert.throws(() => D.createFixturePackageCenter(api), { code:'unavailable' });
});
test('revocation while overview is pending prevents late removal', async () => {
  const api = M.createFixtureAdapter(), session = await api.beginFixtureSession(), original = api.overview;
  let release; const delayed = { ...api, overview: async s => { const value = await original(s); await new Promise(resolve => { release = resolve; }); return value; } };
  const center = D.createFixturePackageCenter(delayed), source = center.forSession(session); const pending = source.uninstall('qbittorrent');
  await new Promise(resolve => setImmediate(resolve)); await api.endSession(session); release(); await assert.rejects(pending, { code: 'denied' });
  const next = center.forSession(await api.beginFixtureSession()); const list = next.list();
  await new Promise(resolve => setImmediate(resolve)); release(); assert.ok((await list).every(x => x.state === 'installed'));
});

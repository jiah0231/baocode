const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const test = require('node:test');

function fixture() {
  const listeners = {};
  const handlers = [];
  const posted = [];
  const listen = name => ({addListener(fn) {
    if (name === 'message') handlers.push(fn);
    else listeners[name] = fn;
  }});
  listeners.message = (...args) => handlers.map(fn => fn(...args)).find(Boolean);
  const url = 'chrome-extension://fixture/sidepanel.html';
  let tab = {id: 9, title: 'Example', url: 'https://example.test', windowId: 4, groupId: -1};
  let grouped = 0, ungrouped = 0;
  const chrome = {
    sidePanel: {async setPanelBehavior(value) { assert.equal(value.openPanelOnActionClick, true); }},
    runtime: {
      id: 'fixture', getManifest: () => ({version: 'test'}), getURL: () => url, onMessage: listen('message'),
      onStartup: listen('startup'), onInstalled: listen('installed'),
      async getContexts({contextTypes, documentIds}) {
        assert.equal(contextTypes[0], 'SIDE_PANEL');
        const [documentId] = documentIds;
        const windowId = {'panel-a': 4, 'panel-b': 12, 'global-a': -1, 'global-b': -1, forged: -1}[documentId];
        return windowId == null ? [] : [{
          contextType: 'SIDE_PANEL', documentId: documentId === 'forged' ? 'global-a' : documentId, windowId,
        }];
      },
      connectNative: () => ({onMessage: listen('native'), onDisconnect: listen('disconnect'), postMessage(message) { posted.push(message); }}),
    },
    tabs: {
      onCreated: listen('created'), onUpdated: listen('updated'), onRemoved: listen('removed'),
      async query(opts) { return opts.windowId === 4 && opts.active ? [tab] : []; },
      async group() { grouped++; tab.groupId = 1; return 1; },
      async ungroup() { ungrouped++; tab.groupId = -1; },
    },
    tabGroups: {async query() { return []; }, async update() {}, async get() { return {title: 'BaoCode'}; }},
    debugger: {onEvent: listen('debug'), onDetach: listen('detach')},
    alarms: {create() {}, onAlarm: listen('alarm')},
    action: {setBadgeText() {}, setBadgeBackgroundColor() {}, setTitle() {}},
    extension: {async isAllowedFileSchemeAccess() { return false; }},
  };
  const source = fs.readFileSync('browser_extension/background.js', 'utf8');
  for (const [, space, on] of source.matchAll(/'(tabs|windows|tabGroups)\.(on\w+)'/g)) {
    chrome[space] ??= {};
    chrome[space][on] ??= listen(space + '.' + on);
  }
  vm.runInNewContext(source, {chrome, console, navigator: {}, crypto, setTimeout, clearTimeout});
  return {listeners, url, tab, posted, counts: () => ({grouped, ungrouped})};
}

test('native panel opens without sharing; only a trusted explicit action shares the active tab', async () => {
  const {listeners, url, tab, counts} = fixture();
  const sender = {id: 'fixture', url};
  const request = (type, tabId = 9) => new Promise(resolve => {
    assert.equal(listeners.message({type, windowId: 4, tabId}, sender, resolve), true);
  });
  assert.equal((await request('panel.status')).connected, false);
  assert.equal((await request('panel.share')).error, true);
  assert.equal(listeners.message({type: 'panel.share'}, {id: 'fixture', url: 'https://example.test'}, () => assert.fail()), undefined);
  await listeners.native({type: 'bridge', connected: true});
  assert.equal((await request('panel.status')).title, 'Example');
  assert.equal(counts().grouped, 0);
  assert.equal((await request('panel.share', 12)).error, true);
  assert.equal((await request('panel.share')).shared, true);
  assert.equal(counts().grouped, 1);
  assert.equal((await request('panel.unshare')).shared, false);
  assert.equal(counts().ungrouped, 1);
  assert.equal((await request('panel.unshare')).shared, false);
  assert.equal(counts().grouped, 1, 'a stale Stop sharing click must not share the tab');
  assert.equal((await request('panel.share')).shared, true);
  listeners.disconnect();
  assert.equal((await request('panel.status')).connected, false);
  assert.equal((await request('panel.status')).shared, true);
  assert.equal((await request('panel.unshare', 12)).error, true);
  tab.url = 'edge://settings/';
  assert.equal((await request('panel.unshare')).shared, false);
  assert.equal(counts().ungrouped, 2);
  assert.equal((await request('panel.share')).error, true);
  await listeners.native({type: 'bridge', connected: true});
  assert.equal((await request('panel.status')).shared, false);
  assert.equal((await request('panel.status')).canShare, false);
  assert.equal((await request('panel.share')).error, true);
  assert.equal(counts().grouped, 2);
});


test('chat uses the trusted sidebar document window, not caller supplied tab or window', async () => {
  const {listeners, url, posted, counts} = fixture();
  const sender = documentId => ({id: 'fixture', url, documentId});
  const call = (documentId, data) => new Promise(resolve => {
    assert.equal(listeners.message({type: 'panel.chat', action: 'snapshot', ...data},
      sender(documentId), resolve), true);
  });
  assert.equal((await call('panel-a')).error, 'offline');
  await listeners.native({type: 'bridge', connected: true});
  assert.equal((await call('other')).error, 'window');
  assert.equal(listeners.message({type: 'panel.chat'}, {...sender('panel-a'), url: 'https://example.test'},
    () => assert.fail()), undefined);
  const resultA = call('panel-a', {windowId: 12, action: 'send', text: 'hello', messageId: '1'});
  const resultB = call('panel-b', {windowId: 4});
  await new Promise(setImmediate);
  const [a, b] = posted.filter(message => message.type === 'sidebarChat');
  assert.equal(a.windowId, 4);
  assert.equal(a.text, 'hello');
  assert.equal(b.windowId, 12);
  assert.equal(b.text, undefined);
  await listeners.native({type: 'sidebarChatResult', requestId: a.requestId, result: {linked: true}});
  assert.equal((await resultA).linked, true);
  listeners.disconnect();
  assert.equal((await resultB).error, 'offline');
  assert.equal(counts().grouped, 0);
});

test('global side panel without a window ID uses a distinct verified document scope', async () => {
  const {listeners, url, posted} = fixture();
  await listeners.native({type: 'bridge', connected: true});
  const call = (documentId, action, extra = {}) => new Promise(resolve => {
    assert.equal(listeners.message({type: 'panel.chat', windowId: 4, action, ...extra},
      {id: 'fixture', url, documentId}, resolve), true);
  });
  assert.equal((await call('forged', 'snapshot')).error, 'window');
  const pending = [
    call('global-a', 'select', {threadId: '13'}),
    call('global-a', 'snapshot'),
    call('global-b', 'snapshot'),
  ];
  await new Promise(setImmediate);
  const [a, again, b] = posted.filter(message => message.type === 'sidebarChat');
  assert.ok(a.windowId >= 2 ** 32);
  assert.equal(a.windowId, again.windowId);
  assert.equal(a.threadId, '13');
  assert.notEqual(a.windowId, b.windowId);
  for (const request of [a, again, b]) {
    await listeners.native({type: 'sidebarChatResult', requestId: request.requestId, result: {linked: request !== b}});
  }
  assert.deepEqual((await Promise.all(pending)).map(result => result.linked), [true, true, false]);
});

test('verified sidebar loads the conversation catalog without a pairing code', async () => {
  const {listeners, url, posted} = fixture();
  await listeners.native({type: 'bridge', connected: true});
  const call = data => new Promise(resolve => {
    listeners.message({type: 'panel.chat', ...data}, {id: 'fixture', url, documentId: 'panel-a'}, resolve);
  });
  assert.equal((await call({action: 'claim', code: 'ABCDEFGHJK'})).error, 'invalid');
  assert.equal((await call({action: 'list', query: '', offset: -1})).error, 'invalid');
  const pending = call({action: 'list', query: 'Bao', offset: 50, code: 'unused', windowId: 99});
  await new Promise(setImmediate);
  const request = posted.find(message => message.type === 'sidebarChat');
  assert.equal(request.action, 'list');
  assert.equal(request.windowId, 4);
  assert.equal(request.query, 'Bao');
  assert.equal(request.offset, 50);
  assert.equal(request.code, undefined);
  const result = {threads: [{id: '1', title: 'One'}], more: false};
  await listeners.native({type: 'sidebarChatResult', requestId: request.requestId, result});
  assert.deepEqual(await pending, result);
});

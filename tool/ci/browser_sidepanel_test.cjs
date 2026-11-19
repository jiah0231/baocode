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
        const windowId = {'panel-a': 4, 'panel-b': 12}[documentIds[0]];
        return windowId == null ? [] : [{windowId}];
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

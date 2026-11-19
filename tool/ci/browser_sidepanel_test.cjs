const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const test = require('node:test');

test('native panel opens without sharing; only a trusted explicit action shares the active tab', async () => {
  const listeners = {};
  const listen = name => ({addListener(fn) { listeners[name] = fn; }});
  const url = 'chrome-extension://fixture/sidepanel.html';
  let tab = {id: 9, title: 'Example', url: 'https://example.test', windowId: 4, groupId: -1};
  let grouped = 0, ungrouped = 0;
  const chrome = {
    sidePanel: {async setPanelBehavior(value) { assert.equal(value.openPanelOnActionClick, true); }},
    runtime: {
      id: 'fixture', getManifest: () => ({version: 'test'}), getURL: () => url, onMessage: listen('message'),
      onStartup: listen('startup'), onInstalled: listen('installed'),
      connectNative: () => ({onMessage: listen('native'), onDisconnect: listen('disconnect'), postMessage() {}}),
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
  vm.runInNewContext(source, {chrome, console, navigator: {}});
  const sender = {id: 'fixture', url};
  const request = (type, tabId = 9) => new Promise(resolve => {
    assert.equal(listeners.message({type, windowId: 4, tabId}, sender, resolve), true);
  });
  assert.equal((await request('panel.status')).connected, false);
  assert.equal((await request('panel.share')).error, true);
  assert.equal(listeners.message({type: 'panel.share'}, {id: 'fixture', url: 'https://example.test'}, () => assert.fail()), undefined);
  await listeners.native({type: 'bridge', connected: true});
  assert.equal((await request('panel.status')).title, 'Example');
  assert.equal(grouped, 0);
  assert.equal((await request('panel.share', 12)).error, true);
  assert.equal((await request('panel.share')).shared, true);
  assert.equal(grouped, 1);
  assert.equal((await request('panel.unshare')).shared, false);
  assert.equal(ungrouped, 1);
  assert.equal((await request('panel.unshare')).shared, false);
  assert.equal(grouped, 1, 'a stale Stop sharing click must not share the tab');
  assert.equal((await request('panel.share')).shared, true);
  listeners.disconnect();
  assert.equal((await request('panel.status')).connected, false);
  assert.equal((await request('panel.status')).shared, true);
  assert.equal((await request('panel.unshare', 12)).error, true);
  tab.url = 'edge://settings/';
  assert.equal((await request('panel.unshare')).shared, false);
  assert.equal(ungrouped, 2);
  assert.equal((await request('panel.share')).error, true);
  await listeners.native({type: 'bridge', connected: true});
  assert.equal((await request('panel.status')).shared, false);
  assert.equal((await request('panel.status')).canShare, false);
  assert.equal((await request('panel.share')).error, true);
  assert.equal(grouped, 2);
});

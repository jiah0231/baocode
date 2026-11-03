// Runs the production injected recorder without Chrome, a DOM, or networking.
// Usage: node test/browser/fixtures/watch_takeover_test.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../../../lib/browser/browser_watch.dart'), 'utf8');
const match = source.match(/static const _watchScript = r'''([\s\S]*?)''';/);
assert.ok(match, 'production recorder script exists');

for (const name of ['__baoWatch', '__baoHistory']) {
  const listeners = new Map();
  const timers = new Map();
  const sent = [];
  let timerId = 0;
  class Element {
    constructor() {
      this.tagName = 'INPUT'; this.type = 'text'; this.id = 'login';
      this.value = 'private login'; this.isContentEditable = false;
      this.labels = []; this.nodeType = 1; this.parentElement = null;
    }
    getAttribute() { return null; }
    closest() { return this; }
  }
  const window = {
    [`${name}Step`]: (value) => sent.push(JSON.parse(value)),
    addEventListener: (type, listener) => listeners.set(type, listener),
    removeEventListener: (type, listener) => {
      if (listeners.get(type) === listener) listeners.delete(type);
    },
  };
  const context = vm.createContext({
    window, Element, document: {}, CSS: {escape: (value) => value},
    scrollY: 40,
    setTimeout: (callback) => { timers.set(++timerId, callback); return timerId; },
    clearTimeout: (id) => timers.delete(id),
  });
  const script = match[1].replaceAll('__baoWatch', name);
  const field = new Element();
  vm.runInContext(script.replaceAll('__BAO_WATCH_TOKEN__', 'old-recorder'), context);
  listeners.get('input')({isTrusted: true, target: field});
  listeners.get('scroll')({isTrusted: true, target: context.document});
  assert.equal(timers.size, 2, 'both input and scroll are queued');
  window[name].stop(true);
  assert.equal(sent.length, 0, 'takeover must discard, never flush');
  assert.equal(timers.size, 0, 'discard clears every timer');
  assert.equal(listeners.size, 0, 'discard removes every listener');
  assert.equal(window[name], undefined);

  // A new authorized recorder cannot flush the previous recorder's input.
  vm.runInContext(script.replaceAll('__BAO_WATCH_TOKEN__', 'new-recorder'), context);
  for (const callback of [...timers.values()]) callback();
  assert.equal(sent.length, 0, 'resume does not replay old private input');
  field.value = 'new authorized input';
  listeners.get('input')({isTrusted: true, target: field});
  for (const callback of [...timers.values()]) callback();
  assert.equal(sent.length, 1);
  assert.equal(sent[0].value, 'new authorized input');
  assert.equal(sent[0].recording, 'new-recorder', 'generation is explicit');
  window[name].stop(true);
}
console.log('PASS: watch/history discard timers, remove listeners, and isolate recording generations');

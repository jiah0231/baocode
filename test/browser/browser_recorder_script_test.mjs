import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';

const source = readFileSync(new URL('../../lib/browser/browser_watch.dart', import.meta.url), 'utf8');
const script = source.match(/static const _watchScript = r'''([\s\S]*?)''';/)[1];

function page(kind = 'Watch') {
  const listeners = new Map();
  const timers = new Map();
  const received = [];
  let timerId = 0;
  class Element {
    constructor(value = 'ordinary input', type = 'text') {
      Object.assign(this, { value, type, tagName: 'INPUT', id: 'field', nodeType: 1,
        parentElement: null, isContentEditable: false, labels: [], innerText: '' });
    }
    getAttribute(name) { return name === 'name' ? 'field' : null; }
    closest() { return this; }
  }
  const window = {
    addEventListener(type, fn) {
      if (!listeners.has(type)) listeners.set(type, new Set());
      listeners.get(type).add(fn);
    },
    removeEventListener(type, fn) { listeners.get(type)?.delete(fn); },
    [`__bao${kind}Step`](json) { received.push(JSON.parse(json)); },
  };
  const document = { scrollingElement: null };
  const context = vm.createContext({ window, document, Element, CSS: { escape: x => x },
    scrollY: 20, setTimeout(fn) { timers.set(++timerId, fn); return timerId; },
    clearTimeout(id) { timers.delete(id); } });
  const run = token => vm.runInContext(
    script.replaceAll('__baoWatch', `__bao${kind}`).replaceAll('__BAO_WATCH_TOKEN__', token),
    context,
  );
  const emit = (type, target = new Element()) => {
    for (const fn of [...(listeners.get(type) ?? [])]) fn({ type, target, isTrusted: true });
  };
  const tick = () => { for (const [id, fn] of [...timers]) { timers.delete(id); fn(); } };
  return { window, document, Element, listeners, timers, received, run, emit, tick };
}

for (const kind of ['Watch', 'History']) {
  test(`${kind}: normal input retains its explicit recorder token`, () => {
    const p = page(kind); p.run('generation-1');
    p.emit('input'); p.tick();
    assert.equal(p.received.length, 1);
    assert.equal(p.received[0].value, 'ordinary input');
    assert.equal(p.received[0].recording, 'generation-1');
    assert.equal(typeof p.received[0].time, 'number');
  });

  test(`${kind}: takeover stop discards queued input and scroll without flushing`, () => {
    const p = page(kind); p.run('old-generation');
    p.emit('input', new p.Element('PRIVATE MANUAL INPUT'));
    p.emit('scroll', p.document);
    assert.equal(p.timers.size, 2);
    p.window[`__bao${kind}`].stop(true);
    assert.equal(p.timers.size, 0);
    assert.ok([...p.listeners.values()].every(set => set.size === 0));
    p.tick(); p.emit('pagehide');
    assert.deepEqual(p.received, []);
  });

  test(`${kind}: restarting cannot replay the previous generation`, () => {
    const p = page(kind); p.run('old-generation');
    p.emit('input', new p.Element('PRIVATE OLD INPUT'));
    p.window[`__bao${kind}`].stop(true);
    p.run('new-generation');
    p.emit('input', new p.Element('new consented input')); p.tick();
    assert.equal(p.received.length, 1);
    assert.equal(p.received[0].recording, 'new-generation');
    assert.equal(p.received[0].value, 'new consented input');
  });

  test(`${kind}: explicit normal completion still flushes once`, () => {
    const p = page(kind); p.run('generation-1');
    p.emit('input'); p.window[`__bao${kind}`].stop(); p.tick();
    assert.equal(p.received.length, 1);
  });
}

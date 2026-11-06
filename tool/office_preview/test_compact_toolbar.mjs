import test from 'node:test';
import assert from 'node:assert/strict';
import {JSDOM} from 'jsdom';
import {compactPreviewToolbar, compactToolbarCss} from './compact-toolbar.mjs';
import {createView, button, zoomControl} from './vendor/noteboard/plugins/shared/view.mjs';

test('compact chrome preserves original controls and adds named corner actions', () => {
  const dom = new JSDOM('<div id="host"></div>');
  const savedDocument = globalThis.document;
  globalThis.document = dom.window.document;
  try {
    const host = document.getElementById('host');
    let reading = false, reflows = 0, reloads = 0, opens = 0, zoom = 1;
    let changed;
    const view = createView(host, 'very-long-document-name.docx', {
      get: () => reading,
      set: value => { reading = value; changed(value); },
      subscribe: listener => { changed = listener; return () => {}; },
    });
    const zoomer = zoomControl({min: .25, max: 3, step: .1, get: () => zoom, set: value => { zoom = value; }});
    const reflow = button('阅读排版', () => { reflows++; });
    view.toolbar.append(zoomer.element, reflow);
    const controls = compactPreviewToolbar(view.root, {
      canOpenExternal: true,
      onReload: () => { reloads++; },
      onOpenExternal: () => { opens++; },
    });
    const actions = view.toolbar.querySelector('.bao-preview-actions');
    assert.equal(actions.parentElement, view.toolbar);
    assert.equal(actions.textContent, '', 'Host actions must be icons, not large labels.');
    const [reload, external] = actions.querySelectorAll('button');
    assert.equal(reload.getAttribute('aria-label'), '重新加载');
    assert.equal(external.getAttribute('aria-label'), '用系统应用打开');
    assert.equal(view.root.querySelector('[data-bao-compact-toolbar]').textContent, compactToolbarCss);
    assert.equal(view.toolbar.querySelector('.np-name').textContent, 'very-long-document-name.docx');
    // Style only hides the duplicate title; the supplied basename is not changed.
    zoomer.element.querySelectorAll('button')[1].click();
    assert.ok(Math.abs(zoom - 1.1) < 1e-9);
    reflow.click();
    assert.equal(reflows, 1);
    view.toolbar.querySelector('.np-reading').click();
    assert.equal(reading, true);
    assert.equal(host.hasAttribute('data-reading'), true);
    external.click();
    assert.equal(opens, 1);
    controls.setOpenExternalVisible(false);
    assert.equal(external.hidden, true);
    external.click();
    assert.equal(opens, 1);
    controls.setOpenExternalVisible(true);
    external.click();
    assert.equal(opens, 2);
    reload.click(); reload.click();
    assert.equal(reloads, 1, 'A rapid repeat cannot schedule multiple reloads.');
    view.destroy();
    assert.equal(view.root.childNodes.length, 0);
    assert.equal(host.hasAttribute('data-reading'), false);
  } finally {
    globalThis.document = savedDocument;
    dom.window.close();
  }
});

test('compact rules stay toolbar-only and do not enlarge narrow desktop panes', () => {
  assert.match(compactToolbarCss, /\.np-toolbar \.np-name\{display:none\}/);
  assert.match(compactToolbarCss, /height:24px;min-width:24px/);
  assert.match(compactToolbarCss, /order:100;flex-shrink:0/);
  assert.match(compactToolbarCss, /@media\(pointer:coarse\)/);
  assert.doesNotMatch(compactToolbarCss, /max-width:760|overflow:hidden|position:absolute|\.np-word|\.np-scroll/);
  assert.equal(compactPreviewToolbar(null, {}), null);
});

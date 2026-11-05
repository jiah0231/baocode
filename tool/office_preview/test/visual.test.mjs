// Opt-in browser evidence. Never imported by the non-browser validation job.
import assert from 'node:assert/strict';
import { before, after, test } from 'node:test';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const fixturesRoot = path.join(root, 'test/fixtures/office_preview');
const assetsRoot = path.join(root, 'assets/office_preview');
const output = path.resolve(process.env.OFFICE_VISUAL_OUT || path.join(root, 'build/office-visual'));
const manifest = JSON.parse(await readFile(path.join(fixturesRoot, 'manifest.json'), 'utf8'));
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const themes = {
  light: { background: '#f5f6f8', foreground: '#202124', border: '#c7ccd2', surface: '#ffffff' },
  dark: { background: '#17191c', foreground: '#e6e9ef', border: '#4a4e55', surface: '#23262b' },
  contrast: { background: '#000000', foreground: '#ffffff', border: '#ffffff', surface: '#000000' },
  contrastLight: { background: '#ffffff', foreground: '#000000', border: '#000000', surface: '#ffffff' },
};
let server, browser, origin;

before(async () => {
  // Explicit opt-in prevents a static CI job or npm test from silently starting
  // a browser. This is not permission to retry a denied environment operation.
  assert.equal(process.env.BAOCODE_RUN_VISUAL, '1', 'Browser visual execution is opt-in; static checks do not run it.');
  await mkdir(output, { recursive: true });
  server = createServer(async (request, response) => {
    try {
      const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
      const relative = pathname === '/' ? 'index.html' : pathname.slice(1);
      const filename = path.resolve(assetsRoot, relative);
      if (!filename.startsWith(assetsRoot + path.sep)) {
        response.writeHead(403).end(); return;
      }
      const bytes = await readFile(filename);
      const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.wasm': 'application/wasm', '.json': 'application/json', '.woff2': 'font/woff2' }[path.extname(filename)] || 'application/octet-stream';
      response.writeHead(200, { 'Content-Type': mime, 'Cache-Control': 'no-store' }).end(bytes);
    } catch { response.writeHead(404).end(); }
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  origin = `http://127.0.0.1:${server.address().port}`;
  // Never downgrade the sandbox or fall back to another executable after denial.
  const executablePath = process.env.OFFICE_VISUAL_EXECUTABLE;
  assert.ok(executablePath, 'Specify an already authorized browser executable.');
  browser = await chromium.launch({ executablePath, headless: true, chromiumSandbox: true });
  await writeFile(path.join(output, 'environment.json'), JSON.stringify({
    browser: browser.version(), viewport: { width: 1280, height: 960 }, deviceScaleFactor: 1,
    platform: process.platform, viewerSha256: hash(await readFile(path.join(assetsRoot, 'viewer.js'))),
    inputManifestSha256: hash(await readFile(path.join(fixturesRoot, 'manifest.json'))),
    referenceStatus: 'not-yet-reviewed',
  }, null, 2));
}, { timeout: 30000 });

after(async () => {
  await browser?.close();
  if (server) await new Promise(resolve => server.close(resolve));
});

async function settle(page) {
  await page.evaluate(async () => {
    await document.fonts.ready;
    const root = window.BaoOfficeViewer.root;
    await Promise.all([...root.querySelectorAll('img')].map(image => image.decode().catch(() => {})));
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  });
}

async function geometry(page) {
  return page.evaluate(() => {
    const root = window.BaoOfficeViewer.root;
    const nodes = root.querySelectorAll('section.docx,section.docx p,section.docx td,section.docx img,.np-canvas svg,.np-canvas foreignObject,.np-cell,.np-head');
    return [...nodes].slice(0, 2500).map(node => {
      const box = node.getBoundingClientRect(), style = getComputedStyle(node);
      return { tag: node.tagName, class: node.getAttribute('class'), label: node.getAttribute('aria-label'),
        text: node.textContent?.slice(0, 160), x: box.x, y: box.y, width: box.width, height: box.height,
        font: style.fontFamily, fontSize: style.fontSize, color: style.color, background: style.backgroundColor };
    });
  });
}

function closeTo(actual, expected, label, tolerance = 1) {
  assert.ok(Math.abs(actual - expected) <= tolerance, `${label}: expected ${expected}, got ${actual}`);
}

async function wordContract(page) {
  const pages = page.locator('.np-word section.docx');
  assert.equal(await pages.count(), 2, 'Explicit page break must remain exactly two pages.');
  const dimensions = await pages.first().evaluate(node => ({ width: node.offsetWidth, height: node.offsetHeight }));
  closeTo(dimensions.width, 816, 'Word authored Letter width');
  closeTo(dimensions.height, 1056, 'Word authored Letter height');
  const title = page.locator('.np-word').getByText('Authored layout report', { exact: true });
  const style = await title.evaluate(node => ({ color: getComputedStyle(node).color, size: getComputedStyle(node).fontSize }));
  assert.equal(style.color, 'rgb(142, 36, 77)');
  assert.equal(style.size, '32px');
  const merged = page.locator('.np-word td[colspan="2"]').first();
  assert.equal(await merged.count(), 1);
  const image = page.locator('.np-word section.docx img').first();
  await image.waitFor({ state: 'visible' });
  const size = await image.evaluate(node => ({ width: node.width, height: node.height, decoded: node.complete && node.naturalWidth > 0 }));
  assert.equal(size.decoded, true, 'Word picture must really decode, not only exist in XML.');
  closeTo(size.width, 192, 'Word authored image width');
  closeTo(size.height, 96, 'Word authored image height');
  assert.ok((await pages.nth(1).textContent()).includes('SECOND PAGE MARKER'));
  const header = await page.locator('.np-word section.docx header').first().boundingBox();
  const titleBox = await title.boundingBox();
  assert.ok(header && titleBox && header.y < titleBox.y, 'Header must stay above page body.');
  return pages.first();
}

async function slidesContract(page) {
  const svg = page.locator('.np-canvas svg').first();
  await svg.waitFor({ state: 'visible' });
  const viewBox = await svg.evaluate(node => ({ width: node.viewBox.baseVal.width, height: node.viewBox.baseVal.height }));
  closeTo(viewBox.width / viewBox.height, 16 / 9, 'Slide aspect ratio', 0.001);
  const left = page.locator('.np-canvas').getByText('LEFT BLOCK', { exact: true });
  const right = page.locator('.np-canvas').getByText('RIGHT BLOCK', { exact: true });
  const [a, b, canvas] = await Promise.all([left.boundingBox(), right.boundingBox(), svg.boundingBox()]);
  assert.ok(a && b && canvas && a.x + a.width < b.x, 'Separate authored shapes must not collapse or overlap.');
  assert.ok((a.x - canvas.x) / canvas.width < 0.4 && (b.x - canvas.x) / canvas.width > 0.6);
  assert.equal(await page.locator('.np-thumb').count(), 2);
  return svg;
}

async function sheetContract(page) {
  const cell = ref => page.locator(`.np-cell[aria-label^="${ref} "]`);
  const merged = cell('A1');
  await merged.waitFor({ state: 'visible' });
  assert.equal(await cell('B1').count(), 0, 'Merged children must not create overlaid cells.');
  const headers = await page.locator('.np-colhead .np-head[data-col]').evaluateAll(nodes =>
    nodes.filter(node => Number(node.dataset.col) < 6).map(node => node.getBoundingClientRect().width));
  const mergedBox = await merged.boundingBox();
  closeTo(mergedBox.width, headers.reduce((a, b) => a + b, 0), 'Merged cell width');
  closeTo(mergedBox.height, 64, 'Merged two-row height');
  closeTo((await cell('B4').boundingBox()).height, 56, 'Custom row height');
  assert.equal((await cell('B4').textContent()).trim(), '$1,234.50');
  assert.equal((await cell('C4').textContent()).trim(), '2020-01-02');
  assert.equal((await cell('D4').textContent()).trim(), '15.0%');
  assert.equal(await page.locator('.np-sheets button[data-sheet]').count(), 2);
  await page.locator('.np-sheets button[data-sheet="1"]').click();
  await page.locator('.np-cell').getByText('SECOND SHEET MARKER', { exact: true }).waitFor();
  await page.locator('.np-sheets button[data-sheet="0"]').click();
  await merged.waitFor({ state: 'visible' });
  // The upstream plugin does not render workbook cell styles, charts or images.
  // Passing this contract establishes its supported geometry, not Excel fidelity.
  return page.locator('.np-layout');
}

for (const fixture of manifest.fixtures) {
  test(`visual evidence: ${fixture.id}`, { timeout: 120000 }, async () => {
    const context = await browser.newContext({ viewport: { width: 1280, height: 960 }, deviceScaleFactor: 1, locale: 'en-US', timezoneId: 'UTC', reducedMotion: 'reduce' });
    const page = await context.newPage();
    const remote = [], errors = [], popups = [];
    page.on('pageerror', error => errors.push(error.message));
    page.on('popup', popup => { popups.push(popup.url()); void popup.close(); });
    await context.route('**/*', route => {
      const url = route.request().url();
      if (url.startsWith(origin + '/') || /^(data|blob):/.test(url)) return route.continue();
      remote.push(url); return route.abort('blockedbyclient');
    });
    const dir = path.join(output, fixture.id);
    await mkdir(dir, { recursive: true });
    try {
      await page.goto(origin, { waitUntil: 'domcontentloaded' });
      await page.waitForFunction(() => !!window.BaoOfficeViewer?.load);
      const bytes = await readFile(path.join(fixturesRoot, fixture.path));
      assert.equal(hash(bytes), fixture.sha256);
      await page.evaluate(async ({ base64, kind, name, theme }) => {
        window.__officeEvents = [];
        window.addEventListener('bao-office-event', event => window.__officeEvents.push(event.detail));
        window.BaoOfficeViewer.setTheme(theme);
        const bytes = Uint8Array.from(atob(base64), c => c.charCodeAt(0));
        await window.BaoOfficeViewer.load({ kind, name, bytes });
      }, { base64: bytes.toString('base64'), kind: fixture.kind, name: path.basename(fixture.path), theme: themes.light });
      await page.waitForFunction(() => window.__officeEvents.some(event => event.type === 'loaded'), null, { timeout: 45000 });
      await settle(page);
      const paper = fixture.kind === 'docx' ? page.locator('.np-word section.docx').first()
        : fixture.kind === 'pptx' ? page.locator('.np-canvas svg').first() : page.locator('.np-grid');
      await paper.waitFor({ state: 'visible' });
      assert.ok(await paper.evaluate(node => node.getBoundingClientRect().width > 100 && node.getBoundingClientRect().height > 50));
      if (fixture.id === 'authored-docx') await wordContract(page);
      if (fixture.id === 'authored-pptx') await slidesContract(page);
      if (fixture.id === 'authored-xlsx') await sheetContract(page);
      let geometryBefore = await geometry(page);
      await writeFile(path.join(dir, 'geometry.json'), JSON.stringify(geometryBefore, null, 2));
      await page.screenshot({ path: path.join(dir, 'light.png'), animations: 'disabled' });
      // Fixed canvas crops are useful for cross-theme exact equality. Excel's
      // original plugin intentionally themes the whole grid, so only Word/PPT
      // are expected to have identical authored-paper pixels across themes.
      const paperBefore = fixture.kind === 'xlsx' ? null : await paper.screenshot({ animations: 'disabled' });
      if (paperBefore) await writeFile(path.join(dir, 'paper.png'), paperBefore);
      // Locator screenshots can scroll the viewport to expose the paper.
      geometryBefore = await geometry(page);
      for (const [name, theme] of Object.entries(themes).slice(1)) {
        await page.evaluate(theme => window.BaoOfficeViewer.setTheme(theme), theme);
        await settle(page);
        const after = await geometry(page);
        const shape = entries => entries.map(({ color, background, ...rest }) => rest);
        assert.deepEqual(shape(after), shape(geometryBefore), 'Chrome theme must not reflow the document.');
        if (paperBefore) assert.ok(paperBefore.equals(await paper.screenshot({ animations: 'disabled' })), 'Authored paper changed with chrome theme.');
        await page.screenshot({ path: path.join(dir, `${name}.png`), animations: 'disabled' });
      }
      if (fixture.id === 'poi-themes') {
        const thumbs = page.locator('.np-thumb');
        assert.equal(await thumbs.count(), 10);
        for (let index = 0; index < 10; index++) {
          await thumbs.nth(index).click(); await settle(page);
          await page.locator('.np-canvas svg').first().screenshot({ path: path.join(dir, `slide-${index + 1}.png`), animations: 'disabled' });
        }
      }
      assert.deepEqual(remote, [], 'Document attempted external network requests.');
      assert.deepEqual(popups, [], 'Document opened a popup.');
      assert.deepEqual(errors, [], 'Renderer reported an uncaught error.');
      await writeFile(path.join(dir, 'events.json'), JSON.stringify(await page.evaluate(() => window.__officeEvents), null, 2));
    } finally {
      await page.screenshot({ path: path.join(dir, 'last-state.png'), animations: 'disabled' }).catch(() => {});
      await writeFile(path.join(dir, 'runtime.json'), JSON.stringify({ remote, errors, popups, referenceReviewed: false }, null, 2));
      await context.close();
    }
  });
}

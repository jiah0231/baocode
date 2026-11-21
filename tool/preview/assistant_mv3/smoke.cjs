const assert = require('node:assert/strict');
const { mkdir, mkdtemp, rm } = require('node:fs/promises');
const { tmpdir } = require('node:os');
const { join, resolve } = require('node:path');
const { chromium } = require('playwright');

async function main() {
  const [source, screenshots] = process.argv.slice(2).map(path => resolve(path));
  assert(source && screenshots, 'An unpacked extension and screenshot output are required');
  const profile = await mkdtemp(join(tmpdir(), 'baocode-assistant-test-'));
  const blocked = new Set();
  const fatal = [];
  const localWasm = new Set();
  const localMaple = new Set();
  let context;
  let page;
  try {
    await mkdir(screenshots, { recursive: true });
    context = await chromium.launchPersistentContext(profile, {
      channel: 'chromium',
      headless: true,
      viewport: { width: 360, height: 1000 },
      args: [
        `--disable-extensions-except=${source}`,
        `--load-extension=${source}`,
      ],
    });
    await context.route(/^https?:/i, route => {
      blocked.add(route.request().url());
      return route.abort();
    });
    const worker = context.serviceWorkers()[0] ??
      await context.waitForEvent('serviceworker', { timeout: 15000 });
    const url = new URL('/index.html', worker.url()).href;
    assert.equal(new URL(url).protocol, 'chrome-extension:');
    page = await context.newPage();
    page.setDefaultTimeout(15000);
    page.on('pageerror', error => fatal.push(error.message));
    page.on('console', message => {
      if (message.type() === 'error') fatal.push(message.text());
    });
    page.on('response', response => {
      if (!response.ok()) return;
      const asset = new URL(response.url());
      if (asset.host !== new URL(url).host || asset.protocol !== 'chrome-extension:') return;
      if (/\/canvaskit\/.*\.wasm$/.test(asset.pathname)) localWasm.add(asset.pathname);
      if (asset.pathname.endsWith('/MapleMonoNormal-NF-CN-Regular.ttf')) localMaple.add(asset.pathname);
    });
    await page.goto(url);
    const semantics = page.locator('flt-semantics');
    const label = text => semantics.filter({ hasText: text }).first();
    const wait = locator => locator.waitFor({ state: 'attached' });
    await wait(label(/正在处理.*示例任务/s));
    await wait(page.getByRole('group', { name: /中文强调.*inline code/s }));
    await wait(page.getByRole('cell', { name: '流式输出', exact: true }));
    await wait(page.getByRole('group', { name: /lib\/chat\/example\.dart/ }));
    assert(localWasm.size, 'Expected a successful CanvasKit Wasm load from the extension');
    assert(localMaple.size, 'Expected the packaged Maple CJK font to load from the extension');
    console.log('Extension-local renderer and font:', [...localWasm], [...localMaple]);
    await page.screenshot({ path: join(screenshots, '01-running.png') });

    // Emulation checks the installed page still renders when the OS asks
    // for less motion. The widget test verifies the actual clock gating.
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await wait(label(/正在处理.*示例任务/s));
    await page.screenshot({ path: join(screenshots, '02-reduced-motion.png') });
    await page.getByRole('button', { name: 'Complete sample output' }).click();
    const completed = /最后一段已追加/;
    const finalLine = page.getByRole('group', { name: completed }).or(label(completed)).first();
    await wait(label(/已完成/));
    await wait(finalLine);
    await wait(page.getByRole('img', { name: /Mermaid.*flowchart/s }));
    await page.screenshot({ path: join(screenshots, '03-completed.png') });

    await page.getByRole('button', { name: 'Restart sample output' }).click();
    await wait(label(/正在处理.*示例任务/s));
    await finalLine.waitFor({ state: 'detached' });
    assert.deepEqual([...blocked], [], 'Fixture requested external network resources');
    assert.deepEqual(fatal, [], 'Console or page errors while rendering the fixture');
  } catch (error) {
    if (page) {
      console.error('Extension-local renderer and font:', [...localWasm], [...localMaple]);
      console.error('External requests:', [...blocked]);
      console.error('Console/page errors:', fatal);
      console.error(await page.locator('body').ariaSnapshot({ timeout: 2000 }).catch(() => ''));
      await page.screenshot({ path: join(screenshots, 'failure.png'), timeout: 2000 }).catch(() => {});
    }
    throw error;
  } finally {
    try {
      await context?.close();
    } finally {
      await rm(profile, { recursive: true, force: true });
    }
  }
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});

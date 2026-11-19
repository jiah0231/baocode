const zh = chrome.i18n.getUILanguage().toLowerCase().startsWith('zh');
document.documentElement.lang = zh ? 'zh' : 'en';
const strings = zh
  ? ['当前网页', '已连接桌面端', '桌面端未连接', '允许 Agent 使用此标签页', '停止共享', '结束演示', '打开 BaoCode 桌面端后会自动连接。', '当前页面不支持共享。', '操作未完成，请重试。', '无活动网页', '允许后，桌面 Agent 可继续访问此标签页，包括跳转后的页面；从此页打开的新标签页也可能被共享。']
  : ['Current page', 'Desktop connected', 'Desktop disconnected', 'Allow Agent to use this tab', 'Stop sharing', 'Finish demonstration', 'Open BaoCode on your desktop to connect.', 'This page cannot be shared.', 'Could not complete the action. Try again.', 'No active page', 'The desktop Agent can keep accessing this tab after navigation. New tabs opened from it may also be shared.'];
const [heading, online, offline, share, unshare, finish, connect, unsupported, failure, empty, scope] = strings;
const get = (id) => document.getElementById(id);
const button = get('share');
get('heading').textContent = heading;
let windowId, tabId, intent, busy = false, generation = 0;

async function update(action) {
  if (busy) return;
  if (action) {
    busy = true;
    button.disabled = true;
  }
  const current = ++generation;
  try {
    windowId ??= (await chrome.windows.getCurrent()).id;
    const status = await chrome.runtime.sendMessage({
      type: action ?? 'panel.status', windowId, tabId,
    });
    if (current !== generation) return;
    if (!status || status.error) throw new Error();
    tabId = status.tabId;
    get('connection').textContent = status.connected ? online : offline;
    get('connection').dataset.connected = String(status.connected);
    get('tab').textContent = status.title || empty;
    intent = status.watching ? 'panel.finish' : status.shared ? 'panel.unshare' : 'panel.share';
    button.textContent = status.watching ? finish : status.shared ? unshare : share;
    button.disabled = status.watching ? !status.connected
      : !status.shared && (!status.connected || !status.canShare);
    get('hint').textContent = !status.connected ? connect : status.canShare ? scope : unsupported;
  } catch {
    if (current !== generation) return;
    button.disabled = true;
    get('hint').textContent = failure;
  } finally {
    if (action) busy = false;
  }
}

button.textContent = share;
button.disabled = true;
button.addEventListener('click', () => { if (intent && !button.disabled) update(intent); });
chrome.tabs.onActivated.addListener(({windowId: changed}) => {
  if (changed === windowId) update();
});
chrome.tabs.onUpdated.addListener((id, change) => {
  if (id === tabId && (change.title || change.url || 'groupId' in change)) update();
});
update();
setInterval(() => { if (!document.hidden) update(); }, 2000);

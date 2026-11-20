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

// The conversation belongs to this sidebar window, not the active tab.
const copy = zh ? {
  title: '桌面会话', pair: '连接', code: '输入桌面连接码', send: '发送', unlink: '断开会话',
  question: '继续当前会话…', how: '在 BaoCode 桌面命令面板搜索「连接浏览器侧栏到当前会话」。',
  offline: '请打开 BaoCode 桌面版。', timeout: '桌面端未响应，请检查是否为支持侧栏会话的版本。',
  window: '此浏览器无法确认侧栏所在窗口。', codeError: '连接码无效或已过期。',
  busy: '正在回复…', approval: '请在桌面端处理待确认操作。',
  failure: '操作未确认，请先查看桌面会话，避免重复发送。',
  user: '你', assistant: 'BaoCode',
} : {
  title: 'Desktop conversation', pair: 'Connect', code: 'Desktop connection code', send: 'Send', unlink: 'Disconnect',
  question: 'Continue this conversation…', how: 'In the BaoCode command palette, choose “Connect browser sidebar to this conversation”.',
  offline: 'Open BaoCode on your desktop.', timeout: 'No desktop reply. Check that your desktop version supports sidebar chat.',
  window: 'This browser could not verify the sidebar window.', codeError: 'The connection code is invalid or expired.',
  busy: 'Responding…', approval: 'Review the pending approval in the desktop app.',
  failure: 'Action not confirmed. Check the desktop conversation before sending again.',
  user: 'You', assistant: 'BaoCode',
};

const messages = get('messages');
const question = get('question');
const pairCode = get('code');
const chatStatus = get('chatStatus');
let chatLinked = false, chatBusy = false, available = false, pollTimer, notice = '', nextSend;
let pollVersion = 0;
const chatRequest = (action, extra) => chrome.runtime.sendMessage({type: 'panel.chat', action, ...extra});
get('chatTitle').textContent = copy.title;
get('link').textContent = copy.pair;
get('send').textContent = copy.send;
get('unlink').textContent = copy.unlink;
for (const [input, label] of [[question, copy.question], [pairCode, copy.code]]) {
  input.placeholder = label;
  input.setAttribute('aria-label', label);
}
function showChat(state) {
  if (!state || state.error) {
    available = false;
    chatStatus.textContent = notice || copy[state?.error] || copy.failure;
    if (!state || ['offline', 'window', 'timeout'].includes(state.error)) {
      chatLinked = false;
      messages.replaceChildren();
    }
  } else {
    chatLinked = state.linked === true;
    available = chatLinked && state.ready;
    get('chatTitle').textContent = chatLinked ? state.title : copy.title;
    chatStatus.textContent = notice || (!chatLinked ? copy.how
      : state.approval ? copy.approval : state.running ? copy.busy : '');
    if (!chatLinked) messages.replaceChildren();
    else renderMessages(state.items ?? []);
  }
  if (!chatLinked) get('chatTitle').textContent = copy.title;
  get('pair').hidden = chatLinked;
  get('conversation').hidden = !chatLinked;
  get('send').disabled = !available || chatBusy || !question.value.trim();
}
function renderMessages(items) {
  const atBottom = messages.scrollHeight - messages.scrollTop - messages.clientHeight < 40;
  items.forEach(({role, text}, index) => {
    let row = messages.children[index];
    if (!row) {
      row = document.createElement('article');
      row.append(document.createElement('strong'), document.createElement('div'));
      messages.append(row);
    }
    row.firstChild.textContent = role === 'user' ? copy.user : copy.assistant;
    if (row.lastChild.textContent !== text) row.lastChild.textContent = text;
  });
  while (messages.children.length > items.length) messages.lastChild.remove();
  if (atBottom) messages.scrollTop = messages.scrollHeight;
}
async function refreshChat() {
  clearTimeout(pollTimer);
  if (chatBusy || document.hidden) return;
  const version = ++pollVersion;
  try {
    const state = await chatRequest('snapshot');
    if (version === pollVersion) showChat(state);
  } catch {
    if (version === pollVersion) showChat({error: 'offline'});
  } finally {
    if (version === pollVersion) {
      pollTimer = setTimeout(refreshChat, chatLinked ? 700 : 2800);
    }
  }
}
async function chatAction(action, extra) {
  if (chatBusy) return;
  clearTimeout(pollTimer);
  ++pollVersion;
  chatBusy = true;
  get('send').disabled = true;
  get('link').disabled = true;
  get('unlink').disabled = true;
  notice = '';
  try {
    const state = await chatRequest(action, extra);
    if (state?.error === 'code') notice = copy.codeError;
    else if (!state || state.error) notice = copy.failure;
    else if (action === 'send') {
      if (state.linked) {
        if (question.value.trim() === extra.text) question.value = '';
        nextSend = null;
      } else notice = copy.failure;
    } else {
      if (action === 'claim') { pairCode.value = ''; question.value = ''; nextSend = null; }
      if (action === 'unlink') { question.value = ''; nextSend = null; }
      showChat(state);
    }
  } catch {
    notice = copy.failure;
  } finally {
    chatBusy = false;
    get('link').disabled = false;
    get('unlink').disabled = false;
    refreshChat();
  }
}
get('pair').addEventListener('submit', e => {
  e.preventDefault();
  const code = pairCode.value.trim().toUpperCase();
  if (/^[A-Z2-9]{10}$/.test(code)) chatAction('claim', {code});
  else chatStatus.textContent = copy.codeError;
});
get('composer').addEventListener('submit', e => {
  e.preventDefault();
  const text = question.value.trim();
  if (!available || !text) return;
  if (nextSend?.text !== text) nextSend = {text, messageId: crypto.randomUUID()};
  chatAction('send', nextSend);
});
question.addEventListener('input', () => {
  get('send').disabled = !available || chatBusy || !question.value.trim();
});
get('unlink').addEventListener('click', () => chatAction('unlink'));
document.addEventListener('visibilitychange', refreshChat);
refreshChat();

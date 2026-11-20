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

// Conversation selection is local to this verified sidebar window/document.
const copy = zh ? {
  title: '桌面会话', search: '搜索桌面会话', previous: '上一页', next: '下一页',
  send: '发送', unlink: '返回会话列表', question: '继续当前会话…',
  empty: '没有找到会话。', loading: '正在打开会话…',
  offline: '请打开 BaoCode 桌面版。', timeout: '桌面端未响应，请更新桌面版到支持免配对的版本。',
  window: 'Edge 无法确认这是 BaoCode 侧栏，请从扩展图标重新打开。',
  missing: '该会话已不可用，请选另一条。', unavailable: '会话暂不可用，请重试。',
  busy: '正在回复…', approval: '请在桌面端处理待确认操作。',
  failure: '操作未确认，请先查看桌面会话，避免重复发送。',
  user: '你', assistant: 'BaoCode',
} : {
  title: 'Desktop conversations', search: 'Search desktop conversations', previous: 'Previous', next: 'Next',
  send: 'Send', unlink: 'Back to conversations', question: 'Continue this conversation…',
  empty: 'No conversations found.', loading: 'Opening conversation…',
  offline: 'Open BaoCode on your desktop.', timeout: 'No desktop reply. Update the desktop app to a version with direct sidebar access.',
  window: 'Edge could not verify the BaoCode sidebar. Reopen it from the extension icon.',
  missing: 'That conversation is no longer available. Choose another.', unavailable: 'Conversations are temporarily unavailable. Try again.',
  busy: 'Responding…', approval: 'Review the pending approval in the desktop app.',
  failure: 'Action not confirmed. Check the desktop conversation before sending again.',
  user: 'You', assistant: 'BaoCode',
};

const messages = get('messages');
const question = get('question');
const search = get('chatSearch');
const threads = get('threads');
const chatStatus = get('chatStatus');
let chatLinked = false, chatBusy = false, available = false, pollTimer, notice = '', nextSend;
let pollVersion = 0, offset = 0, renderedDirectory = null;
const chatRequest = (action, extra) => chrome.runtime.sendMessage({type: 'panel.chat', action, ...extra});
get('chatTitle').textContent = copy.title;
for (const key of ['send', 'unlink', 'previous', 'next']) get(key).textContent = copy[key];
for (const [input, label] of [[question, copy.question], [search, copy.search]]) {
  input.placeholder = label;
  input.setAttribute('aria-label', label);
}

function showChat(state) {
  if (!state || state.error) {
    available = false;
    chatStatus.textContent = notice || copy[state?.error] || copy.unavailable;
  } else {
    chatLinked = state.linked === true;
    available = chatLinked && state.ready;
    if (chatLinked) {
      get('chatTitle').textContent = state.title;
      chatStatus.textContent = notice || (state.approval ? copy.approval : state.running ? copy.busy : '');
      renderMessages(state.items ?? []);
    } else {
      get('chatTitle').textContent = copy.title;
      messages.replaceChildren();
    }
  }
  get('directory').hidden = chatLinked;
  get('conversation').hidden = !chatLinked;
  get('send').disabled = !available || chatBusy || !question.value.trim();
}
function showDirectory(state) {
  get('directory').hidden = false;
  get('conversation').hidden = true;
  get('chatTitle').textContent = copy.title;
  if (!state || state.error) {
    chatStatus.textContent = notice || copy[state?.error] || copy.unavailable;
    renderedDirectory = null;
    threads.replaceChildren();
    get('previous').hidden = offset === 0;
    get('next').hidden = true;
    return;
  }
  const list = state.threads ?? [];
  chatStatus.textContent = notice || (list.length ? '' : copy.empty);
  const key = JSON.stringify(list);
  if (key !== renderedDirectory) {
    renderedDirectory = key;
    threads.replaceChildren(...list.map(({id, title}) => {
      const row = document.createElement('button');
      row.type = 'button';
      row.textContent = title;
      row.addEventListener('click', () => chatAction('select', {threadId: id}));
      return row;
    }));
  }
  get('previous').hidden = offset === 0;
  get('next').hidden = !state.more;
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
    if (version !== pollVersion) return;
    if (state?.linked) showChat(state);
    else if (!state || state.error) {
      if (chatLinked) showChat(state);
      else showDirectory(state);
    } else {
      if (chatLinked) { question.value = ''; nextSend = null; }
      showChat(state);
      const page = await chatRequest('list', {query: search.value, offset});
      if (version === pollVersion) showDirectory(page);
    }
  } catch {
    if (version === pollVersion) {
      if (chatLinked) showChat({error: 'unavailable'});
      else showDirectory({error: 'unavailable'});
    }
  } finally {
    if (version === pollVersion) {
      pollTimer = setTimeout(refreshChat, chatLinked ? 700 : 4500);
    }
  }
}
async function chatAction(action, extra) {
  if (chatBusy) return;
  clearTimeout(pollTimer);
  ++pollVersion;
  chatBusy = true;
  get('send').disabled = true;
  get('unlink').disabled = true;
  threads.inert = true;
  notice = '';
  if (action === 'select') chatStatus.textContent = copy.loading;
  try {
    const state = await chatRequest(action, extra);
    if (!state || state.error) {
      notice = action === 'send' ? copy.failure : copy[state?.error] || copy.unavailable;
    } else if (action === 'send') {
      if (state.linked) {
        if (question.value.trim() === extra.text) question.value = '';
        nextSend = null;
      } else notice = copy.failure;
    } else {
      question.value = '';
      nextSend = null;
      showChat(state);
    }
  } catch {
    notice = action === 'send' ? copy.failure : copy.unavailable;
  } finally {
    if (notice) chatStatus.textContent = notice;
    chatBusy = false;
    get('unlink').disabled = false;
    threads.inert = false;
    refreshChat();
  }
}
function switchPage(nextOffset, delay = 0) {
  if (chatLinked) return;
  offset = nextOffset;
  notice = '';
  ++pollVersion;
  clearTimeout(pollTimer);
  pollTimer = setTimeout(refreshChat, delay);
}
search.addEventListener('input', () => switchPage(0, 180));
get('previous').addEventListener('click', () => switchPage(Math.max(0, offset - 50)));
get('next').addEventListener('click', () => switchPage(offset + 50));
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

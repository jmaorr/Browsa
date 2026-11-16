// Hello Browsa: the background half of a Browsa plugin.
// One port to Browsa carries both ways: requests from us (with a requestId), events from Browsa.
let browsa;
let nextId = 1;
const pending = new Map();

function connect() {
  browsa = chrome.runtime.connectNative('app.browsa');
  browsa.onMessage.addListener((m) => {
    if (m.requestId && pending.has(m.requestId)) {
      const { resolve, reject } = pending.get(m.requestId);
      pending.delete(m.requestId);
      m.error ? reject(new Error(m.error)) : resolve(m.result);
      return;
    }
    if (m.event === 'command') onCommand(m.id, m.tab);
  });
  browsa.onDisconnect.addListener(() => setTimeout(connect, 2000));
  // A command added at run time: these can change as your data does ("Open PR #214").
  call('commands.register', { id: 'random-article', title: 'Open a Random Wikipedia Article', keywords: ['wiki'] });
}

function call(method, params = {}) {
  const requestId = nextId++;
  return new Promise((resolve, reject) => {
    pending.set(requestId, { resolve, reject });
    browsa.postMessage({ requestId, method, params });
  });
}

async function onCommand(id) {
  if (id === 'say-hi') {
    const info = await call('browsa.info');
    call('ui.toast', { text: `Hi from a plugin, Browsa ${info.version} (API ${info.api})` });
  } else if (id === 'reading-time') {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (!tab) return;
    const [{ result: words }] = await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      func: () => (document.body.innerText.match(/\S+/g) || []).length,
    });
    const minutes = Math.max(1, Math.round(words / 230));
    call('ui.toast', { text: `About ${minutes} min to read (${words.toLocaleString()} words)` });
    await chrome.storage.local.set({ last: { title: tab.title, words, minutes } });
  } else if (id === 'random-article') {
    call('tabs.open', { url: 'https://en.wikipedia.org/wiki/Special:Random' });
  }
}

connect();

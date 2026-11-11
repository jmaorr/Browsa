const ask = (method, params = {}) => chrome.runtime.sendNativeMessage('app.browsa', { method, params });

async function refresh() {
  const page = await ask('page.current').catch((e) => ({ error: e.message }));
  document.getElementById('page').textContent = page && page.url
    ? `${page.title}\n${page.url}\nin ${page.space}` : (page && page.error) || 'No page (or a private one).';
  const { last } = await chrome.storage.local.get('last');
  if (last) document.getElementById('last').textContent = `${last.title}: ${last.minutes} min (${last.words} words)`;
}

document.getElementById('toast').onclick = () => ask('ui.toast', { text: 'Toast from the Hello panel 🍞' });
chrome.tabs.onActivated.addListener(refresh);
chrome.tabs.onUpdated.addListener((_, info) => { if (info.status === 'complete') refresh(); });
chrome.storage.onChanged.addListener(refresh);
refresh();

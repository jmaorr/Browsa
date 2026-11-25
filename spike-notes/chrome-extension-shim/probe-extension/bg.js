chrome.runtime.onMessage.addListener((m, s, r) => { if (m.name !== 'a') return false; r({ from: 'L1 sync' }); });
chrome.runtime.onMessage.addListener((m, s, r) => { if (m.name !== 'b') return false; setTimeout(() => r({ from: 'L2 async' }), 50); return true; });
chrome.runtime.onMessage.addListener((m, s, r) => { if (m.name !== 'c') return false; return Promise.resolve({ from: 'L3 promise' }); });
const t0 = Date.now();
const plog = (l) => { try { chrome.runtime.sendNativeMessage('browsa.log', { line: 'PROBE ' + l }).catch(() => {}); } catch (e) {} };
plog('started');
setInterval(() => plog('heartbeat ' + Math.round((Date.now() - t0) / 1000) + 's'), 1000);
chrome.runtime.onMessage.addListener((m) => { plog('got message ' + JSON.stringify(m)); return false; });

chrome.runtime.onMessage.addListener((m, s, r) => { if (m.name !== 'a') return false; r({ from: 'L1 sync' }); });
chrome.runtime.onMessage.addListener((m, s, r) => { if (m.name !== 'b') return false; setTimeout(() => r({ from: 'L2 async' }), 50); return true; });
chrome.runtime.onMessage.addListener((m, s, r) => { if (m.name !== 'c') return false; return Promise.resolve({ from: 'L3 promise' }); });
const t0 = Date.now();
const plog = (l) => { try { chrome.runtime.sendNativeMessage('browsa.log', { line: 'PROBE ' + l }).catch(() => {}); } catch (e) {} };
plog('started');
setInterval(() => plog('heartbeat ' + Math.round((Date.now() - t0) / 1000) + 's'), 1000);
chrome.runtime.onMessage.addListener((m) => { plog('got message ' + JSON.stringify(m)); return false; });
const req = indexedDB.open('probe-db', 1);
req.onupgradeneeded = () => req.result.createObjectStore('s');
req.onsuccess = () => {
  const db = req.result;
  plog('db open');
  db.onclose = () => plog('DB CLOSED BY BROWSER');
  db.onversionchange = () => plog('db versionchange');
  setInterval(() => { try { db.transaction('s', 'readwrite').objectStore('s').put(Date.now(), 'k').onsuccess = () => {}; } catch (e) { plog('db write failed ' + e); } }, 1000);
};
req.onerror = () => plog('db open error ' + req.error);

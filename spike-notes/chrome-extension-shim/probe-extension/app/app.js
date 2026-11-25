window.__browsaErrors = [];
(async () => {
  const send = (name) => Promise.race([chrome.runtime.sendMessage({ name }), new Promise(r => setTimeout(() => r('timeout'), 3000))]).catch(e => 'error ' + e);
  const result = { a: await send('a'), b: await send('b'), c: await send('c') };
  window.__browsaErrors.push(JSON.stringify(result));
})();

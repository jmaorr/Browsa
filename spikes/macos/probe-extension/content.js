const api = globalThis.browser ?? globalThis.chrome;
api.runtime.sendMessage({ probe: true }).then((result) => {
  const go = () => {
    document.documentElement.dataset.extProbe = JSON.stringify(result === undefined ? { reply: 'undefined' } : result);
  };
  go();
}).catch((error) => {
  document.documentElement.dataset.extProbe = JSON.stringify({ sendMessageError: String(error) });
});

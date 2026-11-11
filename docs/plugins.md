# Building a Browsa plugin (spike, API 1)

A Browsa plugin is an ordinary web extension (Manifest V3) with a `browsa` block in its manifest. It runs
anywhere extensions run; in Browsa it also gets a panel, a sidebar card and ⌘K commands, and can talk to
Browsa itself. Start from `examples/plugins/hello-browsa`.

## Try it
1. Library › **Add Unpacked Folder…** › pick `examples/plugins/hello-browsa`.
2. ⌘K › "Reading Time for This Page", "Say Hi from Hello Browsa", "Open Hello".
3. Turn on Settings › Inspect Element, relaunch, then ⌘K › **Open Plugin Console** to watch messages and
   reload your plugin after edits.

## The manifest block

```json
"permissions": ["nativeMessaging"],
"browsa": {
  "panel":   { "page": "panel.html", "title": "Hello", "icon": "hand.wave" },
  "sidebar": { "page": "sidebar.html", "title": "Hello" },
  "commands": [ { "id": "reading-time", "title": "Reading Time for This Page", "keywords": ["words"] } ]
}
```

`icon` is an SF Symbol name. Pages are files in your extension. The sidebar card shows the first time the
plugin loads; people can remove it from ⌘K.

## Talking to Browsa

Native messaging to the host **`app.browsa`**. Two ways:

```js
// One-off, from any extension page or the background:
const page = await chrome.runtime.sendNativeMessage('app.browsa', { method: 'page.current' });

// A port, from the background, which also receives Browsa's events:
const browsa = chrome.runtime.connectNative('app.browsa');
browsa.onMessage.addListener((m) => {
  if (m.event === 'command') { /* m.id, m.tab: { url, title } */ }
  if (m.requestId) { /* the answer to your request: m.result or m.error */ }
});
browsa.postMessage({ requestId: 1, method: 'ui.toast', params: { text: 'Hi' } });
```

| Method | Params | Answer |
|---|---|---|
| `browsa.info` | | `{ app, version, api, methods }` |
| `page.current` | | `{ url, title, space }`, or `null` for a private tab |
| `ui.toast` | `{ text }` | `true` |
| `tabs.open` | `{ url, space? }` (space by name) | `true` |
| `commands.register` | `{ id, title, keywords?, remove? }` | `true`; the row runs like a manifest command |
| `notes.list` | `{ url? }` | the Notes on that page (or the current one) |
| `panel.show` | `{ id? }` | opens your panel (`plugin:<your id>`) or another tool |
| `badge.set`, `agentTool.result` | | not wired yet in this build |

Events from Browsa on the port: `{ event: "command", id, tab? }`.

## Privacy and trust
- Everything is local. `app.browsa` is answered inside Browsa; no helper app runs.
- A plugin never sees private tabs through `page.current` or command events.
- The add sheet lists the Browsa permissions the block asks for (sidebar, panel, commands).

## Not yet
Agent tools (`agentTools` in the block, exposed over Browsa's MCP server), tab badges, a signed plugin
directory on browsa.app, hot reload on file change.

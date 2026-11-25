#!/usr/bin/env node
// Checks that a browser completes a CLI OAuth "loopback" login, the way `wrangler login`, `gcloud auth login`,
// `vercel login` and `claude` do. See README.md.
//
//   node tools/oauth-loopback-check/check.mjs [--app "Browsa Dev"] [--port 8976] [--host localhost] [--hop local|httpbin]
//
// It starts a callback server that behaves like wrangler's (Node http, listens on `localhost`, waits on a slow
// token exchange before answering, 307s to a "done" page, then closes), and a pretend sign-in page on another port.
// The pretend page has an Allow button that POSTs a form and gets a 302 to the callback, like Cloudflare's consent page.
// With --hop httpbin the 302 comes from https://httpbin.org instead, so the callback is a cross-site redirect from
// a public HTTPS page, as in the real thing.
//
// Every request either server sees is printed, with when its connection closed. The check passes when the callback
// arrives once, with the right code and state, and the browser waits for the answer.

import http from "node:http";
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";

const args = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};
const app = opt("app", null);
const port = Number(opt("port", "8976"));
const host = opt("host", "localhost");
const hop = opt("hop", "local");
const exchangeMs = Number(opt("exchange-ms", "1500"));
const authPort = port + 1;

const state = randomBytes(12).toString("hex");
const code = randomBytes(12).toString("hex");
const redirectUri = `http://${host}:${port}/oauth/callback`;
const callbackURL = `${redirectUri}?code=${code}&state=${state}`;
const t0 = Date.now();
const log = (...m) => console.log(`[${((Date.now() - t0) / 1000).toFixed(2).padStart(6)}s]`, ...m);

let callbacks = 0;
let result = null;

// The CLI's side: like @cloudflare/workers-auth's login server.
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const id = `${req.method} ${url.pathname}${url.search}`;
  log("callback server <-", id, "| from", req.socket.remoteAddress, "| referer", req.headers.referer ?? "-");
  req.socket.once("close", () => log("callback server   connection closed for", url.pathname));
  if (req.method !== "GET") return res.end("OK");
  if (url.pathname !== "/oauth/callback") {
    if (url.pathname === "/done") {
      res.writeHead(200, { "Content-Type": "text/html" });
      return res.end("<title>Signed in</title><h1>Signed in</h1><p>You can close this tab.</p>");
    }
    return; // wrangler never answers other paths
  }
  callbacks += 1;
  if (url.searchParams.get("state") !== state) {
    log("  state doesn't match: an old or changed callback");
    res.writeHead(400, { "Content-Type": "text/html" });
    return res.end("<h1>This callback does not match the pending login</h1>");
  }
  if (url.searchParams.get("code") !== code) {
    log("  code missing or changed:", url.searchParams.get("code"));
    res.writeHead(400, { "Content-Type": "text/html" });
    res.end("<h1>No authorisation code</h1>");
    return finish(false, "code missing or changed");
  }
  let aborted = false;
  req.socket.once("close", () => { if (!res.writableEnded) aborted = true; });
  log(`  exchanging the code (${exchangeMs} ms)…`);
  await new Promise((r) => setTimeout(r, exchangeMs));
  if (aborted) {
    log("  the browser gave up on the callback before the CLI answered");
    return finish(false, "browser closed the callback request early");
  }
  res.writeHead(307, { Location: `http://${host}:${port}/done` });
  res.end(() => finish(true));
});

function finish(ok, why) {
  if (result) return;
  result = { ok, why };
  // Leave the done page up for a moment, as the real CLI's done page is elsewhere.
  setTimeout(() => {
    log(ok ? `PASS: callback arrived ${callbacks}× with the right code and state` : `FAIL: ${why}`);
    process.exit(ok && callbacks === 1 ? 0 : 1);
  }, 1500);
}

// The provider's side: a sign-in page with an Allow button.
const auth = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  log("sign-in page     <-", req.method, url.pathname);
  if (req.method === "POST" && url.pathname === "/allow") {
    const to = hop === "httpbin"
      ? `https://httpbin.org/redirect-to?status_code=302&url=${encodeURIComponent(callbackURL)}`
      : callbackURL;
    res.writeHead(302, { Location: to });
    return res.end();
  }
  res.writeHead(200, { "Content-Type": "text/html" });
  res.end(`<!doctype html><title>Pretend sign-in</title>
<style>body{font:16px -apple-system;margin:15vh auto;max-width:420px;text-align:center}button{font:inherit;padding:10px 28px;border-radius:99px}</style>
<h1>Allow the CLI?</h1><p>Like Cloudflare's consent page. Allow sends you back to <code>${redirectUri}</code>.</p>
<form method="post" action="/allow"><input type="hidden" name="redirect_uri" value="${redirectUri}"><button autofocus>Allow</button></form>`);
});

server.listen(port, host, () => {
  log(`callback server on ${host}:${port} (${JSON.stringify(server.address())})`);
  auth.listen(authPort, "127.0.0.1", () => {
    const start = `http://127.0.0.1:${authPort}/authorize?response_type=code&client_id=check&redirect_uri=${encodeURIComponent(redirectUri)}&state=${state}`;
    log("opening", start, app ? `in ${app}` : "in the default browser");
    spawn("open", app ? ["-a", app, start] : [start], { stdio: "inherit" });
    log("click Allow in the browser");
  });
});

setTimeout(() => { log("FAIL: no callback within 3 minutes"); process.exit(1); }, 180_000);

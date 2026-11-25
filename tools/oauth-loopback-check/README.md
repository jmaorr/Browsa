# OAuth loopback check

CLI tools sign in by opening a provider's page in your browser and waiting on a small server at
`http://localhost:<port>/…` for the browser to come back with a code. `wrangler login` uses
`localhost:8976/oauth/callback`; `gcloud`, `vercel`, `firebase` and `claude` do the same on other ports.

`check.mjs` plays both sides with no account needed:

- a callback server that behaves like wrangler's (Node `http`, listens on `localhost`, waits on a slow
  token exchange before it answers, then 307s and closes), and
- a pretend consent page with an Allow button that POSTs and 302s to the callback.

```sh
node tools/oauth-loopback-check/check.mjs --app "Browsa Dev"            # local consent page
node tools/oauth-loopback-check/check.mjs --app "Browsa Dev" --hop httpbin   # 302 from a public HTTPS page
node tools/oauth-loopback-check/check.mjs --app Safari                  # baseline
```

Click Allow in the tab it opens. It prints every request and when each connection closed, then PASS or
FAIL. It fails when the callback never arrives, arrives twice, loses its `code` or `state`, or the
browser drops the request before the CLI has answered (the CLI then never gets its token).

# DRM check

`index.html` asks the browser's engine which DRM systems it offers to web pages (Encrypted Media Extensions):
FairPlay, Widevine, PlayReady and Clear Key. It plays nothing and needs no account. `docs/drm.md` explains what the
answer means and lists the services that were played by hand.

```sh
cd tools/drm-check && python3 -m http.server 8765 --bind 127.0.0.1
```

Then open `http://localhost:8765` in Browsa (it has to be `localhost` or https: the API only exists in a secure
context). The page prints the result; `await drmCheck()` in the Web Inspector returns it. Save a release's result in
`results/`, named for the app build and the engine it ran on.

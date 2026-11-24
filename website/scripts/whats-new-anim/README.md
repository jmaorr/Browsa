# What's New animations

Explainers for features a screen recording can't show well. Each folder is a page with a
`render(t)` function that draws the frame at `t` seconds, so every take is identical. They share
`kit/` (styles, timing helpers, drawn stand-ins for real sites in `sites.js`/`sites.css`, the renderer and the encoder) and use icons from `public/media/fav/`.

```sh
cd scripts/whats-new-anim
node kit/render.cjs call-guard 30 1.2,3        # stills at 1.2 s and 3 s, to check a frame
node kit/render.cjs call-guard 30              # every frame, into call-guard/frames/ (needs Playwright)
kit/encode.sh call-guard call-guard 0090       # → public/media/whats-new/call-guard.mp4, poster from frame 90
```

`space-routing/` came first and has its own `render.cjs`: `cd space-routing && node render.cjs 30`,
then encode its frames the same way.

`1-3/` holds the Mac 1.3 clips (Library, Split View, pinned folders, Space profiles, Picture in
Picture). They use `library/shared/` for the window on its wallpaper and `1-3/shared/scene.js` for the
pointer and menus: `node kit/render.cjs 1-3/split-view 30 && kit/encode.sh 1-3/split-view split-view 0200`.
Live Folders, Boosts and Performance render straight from `library/<name>` at full size the same way.

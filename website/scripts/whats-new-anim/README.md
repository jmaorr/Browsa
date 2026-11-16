# What's New animations

Explainers for features a screen recording can't show well. Each folder is a page with a
`render(t)` function that draws the frame at `t` seconds, so every take is identical.

```sh
cd scripts/whats-new-anim/space-routing
node render.cjs 30                                  # frames/0000.png … (needs Playwright)
ffmpeg -framerate 30 -i frames/%04d.png -c:v libx264 -pix_fmt yuv420p -crf 22 -movflags +faststart space-routing.mp4
ffmpeg -i frames/0120.png -quality 82 space-routing.webp
```

Then copy both into `public/media/whats-new/`. Icons come from `public/media/fav/`.

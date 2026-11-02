# browsa.app

The Browsa website and privacy policy: a static site in `public/`, served by a small Cloudflare
Worker (`src/index.js`) that also redirects www to the bare domain.

```sh
npx wrangler dev      # preview locally
npx wrangler deploy   # publish to browsa.app
```

`scripts/build-clips.sh` rebuilds the clips and stills in `public/media` from raw simulator captures.

When the app's network behaviour changes, update `public/privacy/index.html` and its date.

## Licenses

The MIT license on this repository doesn't cover `public/vendor/transitions/`, which is
[Transitions.dev](https://transitions.dev/)'s UI generation runtime under its own license
(`LICENSE.txt` in that folder), with one small change so it works under the site's content security
policy. Clips and stills show third-party websites, which belong to their owners.

// Serves the static site, sends www to the bare domain, and owns the download links.

// Where each Download button goes. While a value is null the pages show their "coming soon"
// state, which is what the static HTML says on its own. Set a URL (a .dmg, a GitHub release or a
// store page) and every Download button on the site points there, with its live label, and the
// "coming soon" notes disappear. /download/mac and /download/ios always redirect to the current one.
const DOWNLOADS = {
  mac: null, // e.g. "https://github.com/jmaorr/Browsa/releases/latest/download/Browsa.dmg"
  ios: null, // e.g. "https://apps.apple.com/app/browsa/id0000000000"
};
// Where a download goes while it isn't ready.
const NOT_YET = { mac: "/mac/#get", ios: "/" };

const REDIRECTS = { "/desktop": "/mac/", "/desktop/": "/mac/", "/downloads": "/download/", "/downloads/": "/download/" };

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.hostname === "www.browsa.app") {
      url.hostname = "browsa.app";
      return Response.redirect(url.toString(), 301);
    }
    if (REDIRECTS[url.pathname]) return Response.redirect(new URL(REDIRECTS[url.pathname], url).toString(), 302);

    const platform = url.pathname.match(/^\/download\/(mac|ios)\/?$/)?.[1];
    if (platform) return Response.redirect(new URL(DOWNLOADS[platform] ?? NOT_YET[platform], url).toString(), 302);

    const response = await env.ASSETS.fetch(request);
    const live = Object.entries(DOWNLOADS).filter(([, link]) => link);
    if (!live.length || !response.headers.get("content-type")?.includes("text/html")) return response;

    let rewriter = new HTMLRewriter();
    for (const [name, link] of live) {
      rewriter = rewriter
        .on(`[data-download="${name}"]`, {
          element(el) {
            el.setAttribute("href", link);
            el.removeAttribute("aria-disabled");
            const label = el.getAttribute("data-live-label");
            if (label) el.setInnerContent(label);
          },
        })
        .on(`[data-soon="${name}"]`, {
          element(el) {
            el.remove();
          },
        });
    }
    return rewriter.transform(response);
  },
};

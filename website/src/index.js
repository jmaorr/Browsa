// Serves the static site, sends www to the bare domain, owns the download links, and serves Mac
// releases (the Sparkle appcast, update zips and DMGs) from the RELEASES bucket.

// Where each Download button goes. While a value is null the pages show their "coming soon"
// state, which is what the static HTML says on its own. Set a URL (a .dmg, a GitHub release or a
// store page) and every Download button on the site points there, with its live label, and the
// "coming soon" notes disappear. /download/mac and /download/ios always redirect to the current one.
const DOWNLOADS = {
  mac: null, // Set while there's a release in the bucket: see macDownload() below.
  ios: null, // e.g. "https://apps.apple.com/app/browsa/id0000000000"
};
// The newest Mac DMG. tools/publish-mac.sh replaces it with every release, so the Download
// button always gets the latest build. Until the first release is published it isn't there, and
// the Mac buttons stay "coming soon".
const MAC_DMG = "/mac/releases/Browsa.dmg";

// What each release file is, and how long caches may keep it. Versioned files never change.
// The appcast and Browsa.dmg change with every release, so they're checked each time / hourly.
const RELEASE_TYPES = {
  xml: "application/rss+xml; charset=utf-8",
  zip: "application/zip",
  delta: "application/octet-stream",
  dmg: "application/x-apple-diskimage",
};
function releaseCache(key) {
  if (key === "mac/appcast.xml") return "public, max-age=0, must-revalidate";
  if (key === "mac/releases/Browsa.dmg") return "public, max-age=3600";
  return "public, max-age=31536000, immutable";
}

async function serveRelease(request, env, key) {
  if (request.method !== "GET" && request.method !== "HEAD") return new Response(null, { status: 405, headers: { Allow: "GET, HEAD" } });
  const type = RELEASE_TYPES[key.split(".").pop()];
  if (!type || key.includes("..")) return new Response("Not found", { status: 404 });
  const object = request.method === "HEAD"
    ? await env.RELEASES.head(key)
    : await env.RELEASES.get(key, { range: request.headers, onlyIf: request.headers });
  if (!object) return new Response("Not found", { status: 404 });
  const headers = new Headers({
    "Content-Type": type,
    "Cache-Control": releaseCache(key),
    "ETag": object.httpEtag,
    "Last-Modified": object.uploaded.toUTCString(),
    "Accept-Ranges": "bytes",
    "X-Content-Type-Options": "nosniff",
  });
  if (key.endsWith(".dmg")) headers.set("Content-Disposition", `attachment; filename="${key.split("/").pop()}"`);
  if (request.method === "HEAD") {
    headers.set("Content-Length", object.size);
    return new Response(null, { headers });
  }
  // A failed If-None-Match / If-Modified-Since leaves the body off.
  if (!("body" in object)) return new Response(null, { status: 304, headers });
  if (object.range) {
    const { offset = 0, length = object.size - offset } = object.range;
    headers.set("Content-Range", `bytes ${offset}-${offset + length - 1}/${object.size}`);
    headers.set("Content-Length", length);
    return new Response(object.body, { status: 206, headers });
  }
  headers.set("Content-Length", object.size);
  return new Response(object.body, { headers });
}

// The Mac download link while a DMG is published, else null.
async function macDownload(env) {
  return (await env.RELEASES.head("mac/releases/Browsa.dmg")) ? MAC_DMG : null;
}
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

    if (url.pathname === "/mac/appcast.xml") return serveRelease(request, env, "mac/appcast.xml");
    if (url.pathname.startsWith("/mac/releases/")) return serveRelease(request, env, url.pathname.slice(1));

    // Asked for only where it's used: the download redirects and HTML pages.
    const downloads = async () => ({ ...DOWNLOADS, mac: DOWNLOADS.mac ?? (await macDownload(env)) });
    const platform = url.pathname.match(/^\/download\/(mac|ios)\/?$/)?.[1];
    if (platform) return Response.redirect(new URL((await downloads())[platform] ?? NOT_YET[platform], url).toString(), 302);

    const response = await env.ASSETS.fetch(request);
    if (!response.headers.get("content-type")?.includes("text/html")) return response;
    const live = Object.entries(await downloads()).filter(([, link]) => link);
    if (!live.length) return response;

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

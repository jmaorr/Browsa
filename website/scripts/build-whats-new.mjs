#!/usr/bin/env node
// Builds public/whats-new/index.html from the entries in whats-new/, one Markdown file each.
// Wrangler runs it before every `wrangler dev` and `wrangler deploy` (see wrangler.jsonc), so the
// page can't go stale. Entries marked `draft: true` are left out; pass --drafts to see them too:
//
//   node scripts/build-whats-new.mjs            # the page as it will ship
//   node scripts/build-whats-new.mjs --drafts   # with drafts, marked, for a local look
//
// No dependencies. The front matter is `key: value` lines, and the body is a small Markdown
// subset: paragraphs, *italic*, **bold**, `code` and [links](url). See whats-new/README.md.

import { readFileSync, readdirSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const entriesDir = join(root, "whats-new");
const publicDir = join(root, "public");
const outFile = join(publicDir, "whats-new", "index.html");
const withDrafts = process.argv.includes("--drafts");

const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

function inline(text) {
  return esc(text)
    .replace(/(\w)'(\w)/g, "$1’$2")
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/\*([^*]+)\*/g, "<em>$1</em>")
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_, label, href) => `<a href="${href}">${label}</a>`);
}

function parse(file) {
  const raw = readFileSync(join(entriesDir, file), "utf8").replace(/\r\n/g, "\n");
  const m = raw.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
  if (!m) throw new Error(`${file}: needs front matter between --- lines`);
  const meta = {};
  for (const line of m[1].split("\n")) {
    if (!line.trim() || line.trim().startsWith("#")) continue;
    const kv = line.match(/^([a-z]+):\s*(.*)$/);
    if (!kv) throw new Error(`${file}: can't read "${line}"`);
    meta[kv[1]] = kv[2].replace(/^"(.*)"$/, "$1").trim();
  }
  for (const key of ["title"]) if (!meta[key]) throw new Error(`${file}: needs a ${key}`);
  const draft = meta.draft === "true";
  if (!draft && !/^\d{4}-\d{2}-\d{2}$/.test(meta.date ?? "")) throw new Error(`${file}: a published entry needs date: YYYY-MM-DD`);
  for (const key of ["video", "poster", "image"]) {
    if (meta[key] && !existsSync(join(publicDir, meta[key]))) throw new Error(`${file}: ${meta[key]} isn't in public/`);
  }
  if (meta.order && !/^\d+$/.test(meta.order)) throw new Error(`${file}: order: is a whole number`);
  if ((meta.video || meta.image) && !meta.alt) throw new Error(`${file}: describe the clip or picture in alt:`);
  // A paragraph made only of "- " lines is a list (a fixes post); the others join into one line.
  const paragraphs = m[2].trim().split(/\n\s*\n/).filter(Boolean).map((p) => {
    const lines = p.split("\n");
    return lines.every((l) => l.startsWith("- ")) ? { list: lines.map((l) => l.slice(2)) } : p.replace(/\n/g, " ");
  });
  const slug = file.replace(/\.md$/, "").replace(/^\d{4}-\d{2}-\d{2}-/, "");
  return { ...meta, draft, slug, paragraphs };
}

const formatDate = (d) => new Date(`${d}T12:00:00Z`).toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" });

function media(e) {
  if (e.video) {
    // Every clip plays muted and loops while it's on screen (whats-new.js starts and pauses it).
    // autoplay is there for when the script doesn't run.
    const attrs = `muted loop autoplay playsinline preload="metadata" data-loop`;
    // The poster also sits behind the video as a picture, so a browser that won't start the clip still
    // shows it. (An inline style would be blocked by the site's CSP.)
    const still = e.poster ? `<img src="${esc(e.poster)}" alt="" aria-hidden="true">` : "";
    return `<div class="wn-media">${still}<video ${attrs}${e.poster ? ` poster="${esc(e.poster)}"` : ""} aria-label="${esc(e.alt)}"><source src="${esc(e.video)}" type="video/mp4"></video></div>`;
  }
  if (e.image) return `<div class="wn-media"><img src="${esc(e.image)}" alt="${esc(e.alt)}" loading="lazy"></div>`;
  if (e.scene) return `<div class="wn-media wn-window"><div data-mw data-cycle="${esc(e.scene)}" role="img" aria-label="${esc(e.alt ?? "A drawing of Browsa's Mac window.")}"></div></div>`;
  return e.draft ? `<div class="wn-media wn-empty"><span>Clip to come</span></div>` : "";
}

const block = (p, cls) => p.list
  ? `<ul class="wn-list">${p.list.map((l) => `<li>${inline(l)}</li>`).join("")}</ul>`
  : `<p${cls ? ` class="${cls}"` : ""}>${inline(p)}</p>`;

function article(e) {
  const [first, ...rest] = e.paragraphs;
  const label = [e.platform, e.version && `Version ${e.version}`].filter(Boolean).map(esc).join(" · ");
  const when = e.date ? `<time datetime="${e.date}">${formatDate(e.date)}</time>` : "<span>Not yet dated</span>";
  return `
  <article class="wn-entry${e.draft ? " is-draft" : ""}" id="${esc(e.slug)}">
    <header class="wn-meta">
      ${when}
      ${label ? `<span>${label}</span>` : ""}
      ${e.draft ? `<span class="wn-draft">Draft</span>` : ""}
    </header>
    <div class="wn-body">
      ${media(e)}
      <h2><a href="#${esc(e.slug)}">${inline(e.title)}</a></h2>
      ${first ? block(first, "") : ""}
      ${rest.map((p) => block(p, "wn-note")).join("\n      ")}
    </div>
  </article>`;
}

const files = readdirSync(entriesDir).filter((f) => f.endsWith(".md") && !f.startsWith("_") && f !== "README.md");
const entries = files.map(parse)
  .filter((e) => withDrafts || !e.draft)
  // Newest first; undated drafts sit at the top, where they'd land.
  // Within a day, by order: (the release notes' order), then by name.
  .sort((a, b) => (b.date ?? "9999").localeCompare(a.date ?? "9999") || (Number(a.order ?? 999) - Number(b.order ?? 999)) || a.slug.localeCompare(b.slug));
const needsWindow = entries.some((e) => e.scene && !e.video && !e.image);

const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>What’s New, Browsa</title>
<meta name="description" content="New in Browsa for Mac and iPhone: what changed, with a short look at each.">
<meta name="color-scheme" content="light dark">
<meta name="theme-color" media="(prefers-color-scheme: light)" content="#f5f4f1">
<meta name="theme-color" media="(prefers-color-scheme: dark)" content="#121211">
<link rel="canonical" href="https://browsa.app/whats-new/">
<link rel="icon" href="/favicon.png">
<link rel="stylesheet" href="/styles.css">
${needsWindow ? `<link rel="stylesheet" href="/desktop.css">\n<script type="module" src="/desktop.js"></script>\n` : ""}<script type="module" src="/whats-new.js"></script>
</head>
<!-- Built by scripts/build-whats-new.mjs from whats-new/*.md. Edit those, not this file. -->
<body>
<header class="bar">
  <a class="brand" href="/"><img src="/media/orb.webp" alt="" width="26" height="26">Browsa</a>
  <nav aria-label="Main">
    <a href="/">iPhone</a>
    <a href="/mac/">Mac</a>
    <a href="/whats-new/" aria-current="page">What’s New</a>
    <a href="/download/">Download</a>
    <a class="nav-gh" href="https://github.com/jmaorr/Browsa">GitHub</a>
  </nav>
</header>

<main class="wn">
  <h1>What’s New</h1>
  <p class="lead">The changes worth knowing about, with a short look at each. The full list for every update is in its release notes.</p>
${entries.map(article).join("\n")}
${entries.length ? "" : `  <p class="wn-none">Nothing here yet.</p>\n`}</main>

<footer class="foot">
  <span class="brand"><img src="/media/orb.webp" alt="" width="20" height="20">Browsa</span>
  <span>Made by <a href="https://orriginal.me">Joshua Orr</a></span>
  <a href="/whats-new/">What’s New</a>
  <a href="/privacy/">Privacy</a>
  <a href="/support/">Support</a>
  <a href="https://github.com/jmaorr/Browsa">GitHub</a>
  <a href="mailto:hello@orriginal.me">Contact</a>
</footer>
</body>
</html>
`;

mkdirSync(dirname(outFile), { recursive: true });
writeFileSync(outFile, html);
const drafts = entries.filter((e) => e.draft).length;
console.log(`What's New: ${entries.length - drafts} published${withDrafts ? `, ${drafts} drafts shown` : ""} → public/whats-new/index.html`);

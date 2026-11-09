// Made-up websites for the drawn Mac window, so the demos show real-looking pages instead of
// grey boxes. None of these brands exist. Northwind is the same shop SpikeBrowsa serves on
// localhost, so the drawings and any film recorded from SpikeBrowsa show the same thing.

// SF Symbol look-alikes, drawn on a 24-unit grid with round strokes.
const path = (d, extra = "") => `<svg viewBox="0 0 24 24" aria-hidden="true"${extra}>${d}</svg>`;
export const ICON = {
  sidebarLeft: path('<rect x="3" y="5" width="18" height="14" rx="3"/><path d="M9 5v14"/>'),
  sidebarRight: path('<rect x="3" y="5" width="18" height="14" rx="3"/><path d="M15 5v14"/>'),
  back: path('<path d="M14.5 6 8.5 12l6 6"/>'),
  forward: path('<path d="M9.5 6l6 6-6 6"/>'),
  reload: path('<path d="M19 12a7 7 0 1 1-2.05-4.95"/><path d="M19 4.5V8h-3.5"/>'),
  lock: path('<rect x="6.5" y="10.5" width="11" height="9" rx="2" class="fill"/><path d="M9 10.5V8a3 3 0 0 1 6 0v2.5"/>'),
  plus: path('<path d="M12 5v14M5 12h14"/>'),
  download: path('<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5v8M8.5 12.5 12 16l3.5-3.5"/>'),
  house: path('<path class="fill" d="M4 11.2 12 4.5l8 6.7V19a1 1 0 0 1-1 1h-4.5v-5h-5v5H5a1 1 0 0 1-1-1z"/>'),
  briefcase: path('<rect class="fill" x="3.5" y="7.5" width="17" height="12" rx="2.5"/><path d="M9 7.5V6a1.5 1.5 0 0 1 1.5-1.5h3A1.5 1.5 0 0 1 15 6v1.5"/>'),
  sparkles: path('<path class="fill" d="M10 3.5 11.7 8.3 16.5 10 11.7 11.7 10 16.5 8.3 11.7 3.5 10 8.3 8.3z"/><path class="fill" d="M17.5 14l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8z"/>'),
  search: path('<circle cx="10.5" cy="10.5" r="6"/><path d="m15 15 4.5 4.5"/>'),
  searchPlus: path('<circle cx="10.5" cy="10.5" r="6"/><path d="m15 15 4.5 4.5M10.5 8v5M8 10.5h5"/>'),
  ret: path('<path d="M19 6v5a2 2 0 0 1-2 2H6"/><path d="m9.5 9.5-3.5 3.5 3.5 3.5"/>'),
  book: path('<path d="M5 5.5A1.5 1.5 0 0 1 6.5 4H18v14H6.5A1.5 1.5 0 0 0 5 19.5z"/><path d="M5 19.5A1.5 1.5 0 0 0 6.5 21H18v-3"/>'),
  bubble: path('<path d="M5 6.5A2.5 2.5 0 0 1 7.5 4h9A2.5 2.5 0 0 1 19 6.5v6a2.5 2.5 0 0 1-2.5 2.5H11l-4 3.5V15h0a2.5 2.5 0 0 1-2-2.5z"/><path d="M8.5 8.5h7M8.5 11.5h4.5"/>'),
  radar: path('<circle class="fill" cx="12" cy="12" r="1.8"/><path d="M8.5 15.5a5 5 0 0 1 0-7M15.5 8.5a5 5 0 0 1 0 7M5.6 18.4a9 9 0 0 1 0-12.8M18.4 5.6a9 9 0 0 1 0 12.8"/>'),
  key: path('<circle cx="8.5" cy="12" r="4"/><path d="M12.5 12H20M17 12v3M20 12v2.5"/>'),
  puzzle: path('<path d="M9 4.5a2 2 0 1 1 4 0V6h3.5a1 1 0 0 1 1 1v3.5H19a2 2 0 1 1 0 4h-1.5V18a1 1 0 0 1-1 1H13v-1.5a2 2 0 1 0-4 0V19H5.5a1 1 0 0 1-1-1v-3.5H6a2 2 0 1 0 0-4H4.5V7a1 1 0 0 1 1-1H9z"/>'),
  moon: path('<path class="fill" d="M19 14.5A7.5 7.5 0 0 1 9.5 5a7.5 7.5 0 1 0 9.5 9.5z"/>'),
  shield: path('<path class="fill" d="M12 3.5 19 6v5.5c0 4.3-3 7.6-7 9-4-1.4-7-4.7-7-9V6z"/>'),
  chevronDown: path('<path d="m7 10 5 5 5-5"/>'),
  check: path('<circle class="fill" cx="12" cy="12" r="9"/><path class="knock" d="m8 12.2 2.7 2.7L16 9.5"/>'),
  stop: path('<rect class="fill" x="7" y="7" width="10" height="10" rx="2"/>'),
  cursor: path('<path class="fill" d="M6 3.5 18 13l-5.2.7 3 6-2.4 1.2-3-6L6 18.5z"/>'),
};

// Invented site icons, as favicons are drawn: small and flat.
export const FAV = {
  ws: '<i class="fav f-ws">W</i>',
  kitchen: '<i class="fav f-kitchen"></i>',
  rail: '<i class="fav f-rail"></i>',
  nw: '<i class="fav f-nw">N</i>',
  tern: '<i class="fav f-tern"></i>',
  pine: '<i class="fav f-pine"></i>',
  forge: '<i class="fav f-forge"></i>',
  post: '<i class="fav f-post"></i>',
};

// Wander & Salt, a travel journal. The hero is a drawn fjord rather than a photo, so it stays
// crisp and needs no licence.
const FJORD = `<svg class="s-fjord" viewBox="0 0 640 300" preserveAspectRatio="xMidYMid slice" aria-hidden="true">
  <defs>
    <linearGradient id="sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#0d1b3a"/><stop offset=".55" stop-color="#2b3f74"/><stop offset="1" stop-color="#e6a37c"/></linearGradient>
    <linearGradient id="aur" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#47f0b5" stop-opacity="0"/><stop offset=".35" stop-color="#47f0b5" stop-opacity=".75"/><stop offset=".7" stop-color="#7fd6ff" stop-opacity=".5"/><stop offset="1" stop-color="#7fd6ff" stop-opacity="0"/></linearGradient>
    <linearGradient id="sea" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#d79a7a"/><stop offset=".25" stop-color="#3a4f7e"/><stop offset="1" stop-color="#101a33"/></linearGradient>
  </defs>
  <rect width="640" height="300" fill="url(#sky)"/>
  <path class="s-aurora" d="M-20 70 C 120 20, 220 120, 360 60 S 560 30, 680 80 L 680 120 C 560 80, 460 140, 340 105 S 100 70, -20 115z" fill="url(#aur)"/>
  <g fill="#fff" opacity=".8"><circle cx="60" cy="30" r="1"/><circle cx="150" cy="18" r=".8"/><circle cx="420" cy="22" r="1"/><circle cx="520" cy="44" r=".7"/><circle cx="600" cy="16" r="1"/><circle cx="300" cy="12" r=".7"/></g>
  <path d="M0 200 L70 120 L110 150 L170 70 L230 160 L280 130 L330 190 L0 190z" fill="#24335c"/>
  <path d="M260 200 L340 110 L380 140 L440 60 L500 140 L560 100 L640 170 L640 200z" fill="#1d2a4d"/>
  <path d="M170 70 L188 92 L178 90 L170 100 L162 88 L152 92z M440 60 L458 84 L447 82 L440 92 L432 80 L423 85z" fill="#dfe6f5" opacity=".9"/>
  <rect y="196" width="640" height="104" fill="url(#sea)"/>
  <path d="M0 200 L70 250 L110 228 L170 290 L230 222 L280 240 L330 200z" fill="#24335c" opacity=".35"/>
  <g><rect x="372" y="184" width="22" height="14" fill="#b8352b"/><path d="M370 185 L383 175 L396 185z" fill="#8f251e"/><rect x="398" y="187" width="18" height="11" fill="#c2412f"/><path d="M396 188 L407 180 L418 188z" fill="#8f251e"/>
  <rect x="379" y="189" width="4" height="4" fill="#ffd27a"/><rect x="404" y="191" width="3" height="3" fill="#ffd27a"/>
  <rect x="366" y="197" width="58" height="3" fill="#3b2a22"/></g>
  <g opacity=".35"><rect x="372" y="202" width="22" height="10" fill="#b8352b"/><rect x="398" y="202" width="18" height="8" fill="#c2412f"/></g>
</svg>`;

export const travelBlog = `
<div class="site s-ws">
  <header class="ws-nav"><b>Wander <em>&amp;</em> Salt</b><nav><span>Journal</span><span>Places</span><span>Field guides</span><span>About</span></nav><u>Subscribe</u></header>
  <article class="ws-article">
    <p class="ws-kicker">Norway · 9 min read</p>
    <h1>Chasing light in Lofoten</h1>
    <p class="ws-by"><i></i>Maren Holt · January</p>
    <figure class="ws-hero">${FJORD}</figure>
    <p class="ws-body">The sun barely clears the mountains in January, and when it does the whole fjord turns the colour of apricots for an hour. We rented a red fisherman's cabin in Hamnøy, set an alarm for the aurora forecast, and mostly ignored it in favour of the window.</p>
    <p class="ws-body">What follows is everything we'd tell a friend: where to stay, how the ferries really run in winter, and the two hikes worth doing in the snow.</p>
  </article>
</div>`;

export const devDocs = `
<div class="site s-tern">
  <header class="tn-top"><b>${FAV.tern}tern<em>docs</em></b><span class="tn-search">${ICON.search}Search docs<kbd>/</kbd></span><nav><span>Guides</span><span>API</span><span>Changelog</span></nav></header>
  <div class="tn-body">
    <nav class="tn-side">
      <p>Get started</p><span>Quickstart</span><span>Authentication</span>
      <p>Events</p><span class="on">Webhooks</span><span>Event types</span><span>Retries</span>
      <p>SDKs</p><span>JavaScript</span><span>Swift</span><span>Go</span>
    </nav>
    <main class="tn-main">
      <p class="tn-crumb">Events / Webhooks</p>
      <h1>Webhooks</h1>
      <p class="tn-lede">Tern sends a signed POST to your endpoint whenever something happens in your account. Verify the signature, then hand the event to your queue.</p>
      <pre class="tn-code"><span class="c">// app/api/tern/route.ts</span>
<span class="k">const</span> event = tern.webhooks.<span class="f">verify</span>(body, req.headers[<span class="s">"tern-signature"</span>]);
<span class="k">if</span> (event.type === <span class="s">"payment.succeeded"</span>) <span class="k">await</span> <span class="f">fulfil</span>(event.data);</pre>
      <p class="tn-note"><b>Retries</b> Failed deliveries back off for up to 72 hours.</p>
      <div class="tn-rows"><span><code>payment.succeeded</code>A charge went through</span><span><code>payment.failed</code>The card was declined</span><span><code>refund.created</code>Money is on its way back</span></div>
    </main>
  </div>
</div>`;

// Northwind, the shop SpikeBrowsa serves on localhost. Its fields can fill in: the agent and
// password manager scenes reveal the .fill text.
export const shop = `
<div class="site s-nw">
  <header class="nw-top"><b>Northwind</b><nav><span>Shop</span><span>Cart</span><span class="on">Checkout</span></nav></header>
  <div class="nw-body">
    <form class="nw-form" aria-hidden="true">
      <h1>Checkout</h1>
      <label>Email</label><span class="nw-field"><span class="fill f1">ada@northwind.dev</span><i class="nw-key">${ICON.key}</i></span>
      <label>Password</label><span class="nw-field"><span class="fill f2">••••••••••••</span></span>
      <label>Name on card</label><span class="nw-field"><span class="fill f3">Ada Lovelace</span></span>
      <span class="nw-pay">Pay $329</span>
    </form>
    <aside class="nw-summary">
      <p>Order summary</p>
      <div class="nw-item"><i class="sw1"></i><span>Linen Shirt<em>Sand · M</em></span><b>$89</b></div>
      <div class="nw-item"><i class="sw2"></i><span>Field Jacket<em>Olive · M</em></span><b>$240</b></div>
      <div class="nw-total"><span>Total</span><b>$329</b></div>
    </aside>
  </div>
</div>`;

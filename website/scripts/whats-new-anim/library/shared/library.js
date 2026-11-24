// Shared bits for the Library's card loops: a Browsa window on a wallpaper, with the real
// sidebar's parts (favourites, sections, rows, Radar's card, Space dots).
const F = (n) => `../../../../public/media/fav/${n}.png`;
const img = (n) => `<img src="${F(n)}">`;
const R = (icon, title, cls = "", id = "") => `<div class="row ${cls}" ${id ? `id="${id}"` : ""}><div class="in">${icon}<span>${title}</span></div></div>`;
const DEV = (c1, c2) => `<span style="width:22px;height:22px;border-radius:6px;background:linear-gradient(135deg,${c1},${c2});flex:none"></span>`;
const CLAUDE = `<svg width="15" height="15" viewBox="0 0 24 24" fill="#fff"><path d="M12 2l1.6 6.2L20 6l-4.4 4.8L22 12l-6.4 1.2L20 18l-6.4-2.2L12 22l-1.6-6.2L4 18l4.4-4.8L2 12l6.4-1.2L4 6l6.4 2.2z"/></svg>`;
const RADAR_ICON = `<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="#5d5a55" stroke-width="2.2" stroke-linecap="round"><circle cx="12" cy="12" r="2"/><path d="M7.8 7.8a6 6 0 000 8.4M16.2 7.8a6 6 0 010 8.4M5 5a10 10 0 000 14M19 5a10 10 0 010 14"/></svg>`;
const POINTER = (fill) => `<svg width="30" height="30" viewBox="0 0 22 30"><path d="M2 2v22l6-6 4 9 4-2-4-9h8z" fill="${fill}" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></svg>`;
const sidebar = ({ addr = "", favs = ["mail.google.com", "calendar.google.com", "figma.com", "notion.so"], body = "", foot = "", space = 1, tint = "#ff9500" }) => `
  <div class="lights"><i></i><i></i><i></i></div>
  <div class="addr" id="addr">${addr}</div>
  ${foot && foot.top ? foot.top : ""}
  <div class="favs">${favs.map((f) => `<span>${img(f)}</span>`).join("")}</div>
  ${body}
  <div style="margin-top:auto">${foot.bottom || ""}</div>
  <div class="spaces">${[0, 1, 2].map((i) => `<i style="${i === space ? `background:${tint}` : ""}"></i>`).join("")}</div>`;

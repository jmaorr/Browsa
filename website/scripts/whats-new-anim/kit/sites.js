// Drawn stand-ins for real sites (see sites.css). Each returns HTML for a page card.
const GH_MARK = `<svg viewBox="0 0 16 16" fill="currentColor"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>`;
const SITES = {
  linear: () => `<div class="site lin"><div class="nav"><b><i></i>Browsa</b><p>Inbox</p><p class="on">My issues</p><p>Projects</p><p>Views</p><p style="margin-top:14px">Team</p><p>Cycles</p></div>
    <div class="main"><div class="head">My issues <span class="on">Assigned</span><span>Created</span><span>Subscribed</span></div>
    <div class="grp"><span class="st prog"></span>In Progress <span style="color:var(--mut);font-weight:500">3</span></div>
    ${[["BRW-212", "Mini-player keeps mute and leave in reach", "Calls", "#4cb782", "prog"], ["BRW-208", "Badge tabs that are on a call", "Calls", "#4cb782", "prog"], ["BRW-199", "Space colours: lighter and darker", "Design", "#bb87fc", "prog"]]
      .map(([id, t, l, c, s]) => `<div class="it"><span class="id">${id}</span><span class="st ${s}"></span>${t}<span class="lb"><i style="background:${c}"></i>${l}</span><span class="av" style="background:#d7a17a"></span></div>`).join("")}
    <div class="grp"><span class="st todo"></span>Todo <span style="color:var(--mut);font-weight:500">4</span></div>
    ${[["BRW-224", "Rename tabs inline", "Tabs"], ["BRW-221", "Favourites in New Tab", "Tabs"], ["BRW-217", "Zoom badge updates while zooming", "Bug"], ["BRW-215", "Drag Spaces into order", "Settings"]]
      .map(([id, t, l]) => `<div class="it"><span class="id">${id}</span><span class="st todo"></span>${t}<span class="lb"><i style="background:${l === "Bug" ? "#eb5757" : "#5e6ad2"}"></i>${l}</span><span class="av" style="background:#8fb3d9"></span></div>`).join("")}
    </div></div>`,
  github: () => `<div class="site gh"><div class="top">${GH_MARK}<span>jmaorr / <b>Browsa</b></span></div>
    <div class="tabs"><span>Code</span><span>Issues</span><span class="on">Pull requests</span><span>Actions</span></div>
    <div class="body"><h1>Mac 1.2: call features, Space themes and tab renaming <span>#88</span></h1>
    <div class="state"><b>Merged</b> 14 commits into main</div>
    <div class="cmt"><div class="h"><b>jmaorr</b> commented</div><div class="t"><p>Adds the call mini-player, call badges and the back-to-call capsule.</p><p>Also: Space themes, favourites in New Tab, and renaming tabs.</p></div></div>
    <div class="chk"><i></i>All checks have passed</div></div></div>`,
  notion: () => `<div class="site no"><div class="crumb">Team / Meetings / Standup notes</div><div class="emo">☕️</div><h1>Standup notes</h1>
    <div class="prop"><span>Date</span><span>19 November</span></div><div class="prop"><span>Attendees</span><span>Ada, Grace, Katherine</span></div>
    <h3>Today</h3><div class="todo done"><i></i><span>Ship the 1.2 release notes</span></div><div class="todo"><i></i><span>Record the mini-player clip</span></div><div class="todo"><i></i><span>Review Space colours</span></div>
    <h3>Notes</h3><ul><li>Calls float in a mini-player when you leave the tab.</li><li>Favourites now show in every new tab.</li></ul></div>`,
};
const site = (name) => SITES[name]();

const { chromium } = require('playwright');
(async () => { const b = await chromium.launch(); const p = await b.newPage({ viewport:{width:1600,height:1000}, deviceScaleFactor:1 });
 await p.goto('file://' + __dirname + '/index.html'); await p.waitForTimeout(500);
 const fps = +process.argv[2] || 30; const only = process.argv[3];
 const total = await p.evaluate(() => TOTAL);
 if (only) { for (const t of only.split(',')) { await p.evaluate(t => render(+t), t); await p.screenshot({ path: `still-${t}.png` }); } await b.close(); return; }
 require('fs').mkdirSync('frames', { recursive: true });
 const n = Math.round(total * fps);
 for (let i = 0; i < n; i++) { await p.evaluate(t => render(t), i / fps); await p.screenshot({ path: `frames/${String(i).padStart(4,'0')}.png` }); }
 await b.close(); console.log(n, 'frames'); })();

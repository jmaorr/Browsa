// node ../kit/render.cjs <scene dir> [fps] [t1,t2 for stills]
const { chromium } = require('playwright'); const path = require('path'); const fs = require('fs');
(async () => {
  const dir = path.resolve(process.argv[2]); const fps = +process.argv[3] || 30; const stills = process.argv[4];
  const b = await chromium.launch({ args: ['--allow-file-access-from-files'] });
  const p = await b.newPage({ viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 1 });
  await p.goto('file://' + dir + '/index.html'); await p.waitForFunction(() => window.render); await p.waitForTimeout(400);
  if (stills) { for (const t of stills.split(',')) { await p.evaluate(t => render(+t), t); await p.screenshot({ path: `${dir}/still-${t}.png` }); } await b.close(); return; }
  fs.rmSync(dir + '/frames', { recursive: true, force: true }); fs.mkdirSync(dir + '/frames');
  const n = Math.round(await p.evaluate(() => TOTAL) * fps);
  for (let i = 0; i < n; i++) { await p.evaluate(t => render(t), i / fps); await p.screenshot({ path: `${dir}/frames/${String(i).padStart(4, '0')}.png` }); }
  await b.close(); console.log(n, 'frames');
})();

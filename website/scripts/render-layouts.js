// Renders the layouts section's animation to PNG frames for docs/media/layouts-*.webp.
// Serve website/public on port 8789, then: node render-layouts.js <empty folder>
// Encode each scheme with: img2webp -loop 0 -lossy -q 72 -m 4 $(cat <folder>/<scheme>.txt) -o layouts-<scheme>.webp
const { chromium } = require("playwright");
const fs = require("fs");
const out = process.argv[2];

(async () => {
  const browser = await chromium.launch({ channel: "chrome" });
  for (const colorScheme of ["light", "dark"]) {
    const context = await browser.newContext({ viewport: { width: 720, height: 720 }, deviceScaleFactor: 1.25, colorScheme });
    await context.addInitScript(() => sessionStorage.setItem("hero-drawn", "1"));
    const page = await context.newPage();
    await page.goto("http://localhost:8789/");
    await page.addStyleTag({
      content: ".m-stage{position:fixed!important;inset:0;width:720px;height:720px;margin:0;padding:16px;z-index:99;background:var(--ground)}html{overflow:hidden}",
    });
    await page.evaluate(() => Promise.all([...document.querySelectorAll(".m-stage img")].map((i) => i.decode())));
    await page.waitForTimeout(400);

    const frames = [];
    const shoot = async (delay) => {
      const file = `${out}/${colorScheme}-${String(frames.length).padStart(4, "0")}.png`;
      await page.screenshot({ path: file });
      frames.push(`-d ${delay} ${file}`);
    };
    await shoot(1400);
    for (const name of ["open", "portrait", "overlay", "closed", "sidebar"]) {
      await page.evaluate((n) => document.querySelector(`[data-layout-pick="${n}"]`).click(), name);
      await page.evaluate(() => {
        window.running = document.getAnimations();
        window.running.forEach((a) => a.pause());
      });
      for (let t = 50; t <= 600; t += 50) {
        await page.evaluate((ms) => window.running.forEach((a) => (a.currentTime = ms)), t);
        await shoot(50);
      }
      await page.evaluate(() => window.running.forEach((a) => a.finish()));
      await page.waitForTimeout(60);
      await shoot(1400);
    }
    fs.writeFileSync(`${out}/${colorScheme}.txt`, frames.join("\n"));
    await context.close();
  }
  await browser.close();
})();

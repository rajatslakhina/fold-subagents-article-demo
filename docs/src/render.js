const { chromium } = require('playwright');
const path = require('path');
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ deviceScaleFactor: 2 });
  for (const [name, w, h] of [['header', 1400, 700], ['diagram', 1400, 820], ['gate', 1400, 760]]) {
    await page.setViewportSize({ width: w, height: h });
    await page.goto('file://' + path.join(__dirname, name + '.html'));
    await page.screenshot({ path: path.join(__dirname, '..', name + '.png') });
  }
  await browser.close();
})();

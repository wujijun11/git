/* Render the existing SVG files exactly; this script never modifies geometry. */
const fs = require('fs');
const path = require('path');
const sharp = require(process.argv[2] || 'sharp');
async function main() {
  for (const name of ['top_preview', 'bottom_preview']) {
    const output = path.join(__dirname, `${name}.png`);
    await sharp(path.join(__dirname, `${name}.svg`), { density: 192 })
      .resize({ width: 2000 }).png().toFile(output);
    console.log(output);
  }
}
main().catch(e => { console.error(e); process.exitCode = 1; });

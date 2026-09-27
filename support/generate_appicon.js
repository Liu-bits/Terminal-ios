// Generates the AppIcon 1024x1024 PNG from the devicon:bash SVG.
// Run with Node (resvg-js must be installed in the node workspace).
const { Resvg } = require('@resvg/resvg-js');
const fs = require('fs');
const https = require('https');

const ICON_ID = 'devicon:bash';
const COLOR = '4FA847'; // bash green, the accent; the logo already carries its own dark background
const OUT_PNG = process.argv[2] || 'AppIcon.png';

const [prefix, name] = ICON_ID.split(':');
const url = `https://api.iconify.design/${prefix}/${name}.svg?width=1024&height=1024&color=%23${COLOR}`;

https.get(url, (res) => {
  const chunks = [];
  res.on('data', (c) => chunks.push(c));
  res.on('end', () => {
    const svg = Buffer.concat(chunks).toString('utf8');
    const resvg = new Resvg(svg, { fitTo: { mode: 'width', value: 1024 } });
    const png = resvg.render().asPng();
    fs.writeFileSync(OUT_PNG, png);
    console.log(`wrote ${OUT_PNG} (${png.length} bytes)`);
  });
}).on('error', (e) => { console.error(e.message); process.exit(1); });

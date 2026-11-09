#!/usr/bin/env python3
"""Renders assets/branding/app_icon.svg into every icon the app ships with:
macOS (AppIcon, AppIcon-Dev), Windows (.ico), the web, the browser extension
and the About dialog. Needs Playwright (Chromium) for Node and Pillow.

    NODE_PATH=$(npm root -g) python3 tool/render_icons.py
"""
import os, re, shutil, subprocess, sys, tempfile
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = (ROOT / 'assets/branding/app_icon.svg').read_text()

RENDER_JS = r"""
const { chromium } = require('playwright');
const fs = require('fs');
(async () => {
  const [svgPath, outDir, ...sizes] = process.argv.slice(2);
  const svg = fs.readFileSync(svgPath, 'utf8');
  const browser = await chromium.launch();
  for (const size of sizes.map(Number)) {
    const page = await browser.newPage({ viewport: { width: size, height: size }, deviceScaleFactor: 1 });
    await page.setContent(`<html><body style="margin:0;background:transparent">${svg.replace(/width="\d+" height="\d+"/, `width="${size}" height="${size}"`)}</body></html>`);
    await page.screenshot({ path: `${outDir}/icon_${size}.png`, omitBackground: true, clip: { x: 0, y: 0, width: size, height: size } });
    await page.close();
  }
  await browser.close();
})();
"""

def variants():
    dev = SRC.replace('fill="#F2FFFB"', 'fill="#F0C674"')
    def bleed(svg):
        s = svg.replace('x="100" y="100" width="824" height="824" rx="188"', 'x="0" y="0" width="1024" height="1024" rx="228"')
        s = s.replace('x="103" y="103" width="818" height="818" rx="185"', 'x="3" y="3" width="1018" height="1018" rx="225"')
        s = re.sub(r'<filter.*?</filter>', '', s, flags=re.S).replace(' filter="url(#shadow)"', '')
        s = s.replace('<g stroke="url(#pi)"', '<g transform="translate(512 512) scale(1.18) translate(-512 -512)"><g stroke="url(#pi)"', 1)
        return s.replace('transform="translate(-34 -14)"/>\n</svg>', 'transform="translate(-34 -14)"/>\n</g></svg>')
    maskable = bleed(SRC).replace('rx="228"', 'rx="0"').replace('rx="225"', 'rx="0"')
    return {'main': (SRC, (1024, 512, 256, 128, 64, 32, 16)),
            'dev': (dev, (1024, 512, 256, 128, 64, 32, 16)),
            'bleed': (bleed(SRC), (512, 256, 192, 128, 64, 48, 32, 24, 16)),
            'bleed_dev': (bleed(dev), (256, 128, 64, 48, 32, 24, 16)),
            'maskable': (maskable, (512, 192))}

def main():
    work = Path(tempfile.mkdtemp())
    (work / 'render.js').write_text(RENDER_JS)
    out = {}
    for name, (svg, sizes) in variants().items():
        (work / f'{name}.svg').write_text(svg)
        (work / name).mkdir()
        subprocess.run(['node', 'render.js', f'{name}.svg', name, *map(str, sizes)], cwd=work, check=True)
        out[name] = work / name
    def cp(src, dst): shutil.copyfile(src, ROOT / dst)
    for n in (16, 32, 64, 128, 256, 512, 1024):
        cp(out['main'] / f'icon_{n}.png', f'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{n}.png')
        cp(out['dev'] / f'icon_{n}.png', f'macos/Runner/Assets.xcassets/AppIcon-Dev.appiconset/app_icon_{n}.png')
    cp(out['main'] / 'icon_128.png', 'assets/branding/app_icon.png')
    cp(out['bleed'] / 'icon_16.png', 'web/favicon.png')
    cp(out['bleed'] / 'icon_192.png', 'web/icons/Icon-192.png')
    cp(out['bleed'] / 'icon_512.png', 'web/icons/Icon-512.png')
    for n in (192, 512):
        Image.open(out['maskable'] / f'icon_{n}.png').convert('RGB').save(ROOT / f'web/icons/Icon-maskable-{n}.png')
    for n in (16, 32, 48, 128):
        cp(out['bleed'] / f'icon_{n}.png', f'browser_extension/icons/icon-{n}.png')
    sizes = [16, 24, 32, 48, 64, 128, 256]
    for variant, dst in (('bleed', 'app_icon.ico'), ('bleed_dev', 'app_icon_dev.ico')):
        imgs = [Image.open(out[variant] / f'icon_{n}.png').convert('RGBA') for n in sizes]
        imgs[-1].save(ROOT / 'windows/runner/resources' / dst, format='ICO',
                      sizes=[(n, n) for n in sizes], append_images=imgs[:-1])
    shutil.rmtree(work)

if __name__ == '__main__':
    main()

import {bundle} from '@remotion/bundler';
import {renderMedia, renderStill, selectComposition} from '@remotion/renderer';
import {mkdir, stat} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import {execFileSync} from 'node:child_process';

const root = path.dirname(fileURLToPath(import.meta.url));
const build = path.join(root, '.build');
const assets = path.resolve(root, '../../app/assets/images');
await mkdir(build, {recursive: true});
await mkdir(assets, {recursive: true});
const start = Date.now();
const serveUrl = await bundle({
  entryPoint: path.join(root, 'src/index.tsx'),
  outDir: path.join(build, 'bundle'),
  publicDir: path.resolve(root, '../../app/assets/fonts'),
});
const browserExecutable = process.env.CHROMIUM_PATH || '/usr/bin/chromium';
const composition = await selectComposition({serveUrl, id: 'Connection', browserExecutable});
const common = {serveUrl, composition, browserExecutable};
for (const [name, frame] of [['before', 60], ['transition', 144], ['connected', 264], ['first', 0], ['last', 431]]) {
  await renderStill({...common, frame, output: path.join(build, `${name}.png`), imageFormat: 'png'});
}
const ffmpeg = (...args) => execFileSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', ...args], {stdio: 'inherit'});
ffmpeg('-i', path.join(build, 'connected.png'), '-c:v', 'libwebp', '-quality', '85', path.join(assets, 'connection-poster.webp'));
if (!process.argv.includes('--stills')) {
  await renderMedia({...common, codec: 'h264', crf: 17, pixelFormat: 'yuv420p', concurrency: 2, outputLocation: path.join(build, 'master.mp4')});
  ffmpeg('-i', path.join(build, 'master.mp4'), '-an', '-vf', 'scale=in_range=auto:out_range=tv', '-color_range', 'tv', '-c:v', 'libx264', '-preset', 'slow', '-crf', '25', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', path.join(assets, 'connection.mp4'));
  ffmpeg('-i', path.join(build, 'master.mp4'), '-an', '-vf', 'scale=in_range=auto:out_range=tv', '-color_range', 'tv', '-c:v', 'libvpx-vp9', '-b:v', '0', '-crf', '36', '-row-mt', '1', '-pix_fmt', 'yuv420p', path.join(assets, 'connection.webm'));
  for (const file of ['connection.mp4', 'connection.webm', 'connection-poster.webp']) {
    const bytes = (await stat(path.join(assets, file))).size;
    const max = file.endsWith('webp') ? 250_000 : 4_000_000;
    if (bytes >= max) throw new Error(`${file}: ${bytes} bytes exceeds ${max}`);
    console.log(`${file}: ${bytes} bytes`);
  }
}
console.log(`Rendered in ${((Date.now() - start) / 1000).toFixed(1)}s. Review stills: ${build}`);

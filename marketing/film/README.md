# Connection — Concourse marketing film

A self-contained, original Remotion composition. Rails serves the three committed
assets; no React, Remotion or Node runtime/build is needed in production.
No audio, stock imagery, external font requests, product data or model calls.
The illustration depicts messaging between three Pi agents, not model execution
or orchestration by Concourse.

## Reproduce locally

Requires Node/npm, system Chromium and ffmpeg with libx264, libvpx-vp9 and libwebp.
Dependencies are exact-pinned in `package.json` and `package-lock.json`.

```sh
cd marketing/film
npm ci --no-audit --no-fund
npm run render
# Only the review PNGs and committed poster:
npm run render -- --stills
```

Chromium defaults to `/usr/bin/chromium`; override with `CHROMIUM_PATH`.
The renderer explicitly passes `browserExecutable`, so it does not download a
browser. All dependencies and scratch output stay inside this directory.
`publicDir` is the repository's `app/assets/fonts`, containing the existing
Figtree and Geist Mono WOFF2s. Rendering waits for both fonts to load.

The implementation uses the installed Remotion 4.0.535 APIs, checked against
`@remotion/bundler/dist/bundle.d.ts` and `@remotion/renderer/dist/` declarations
for `selectComposition`, `renderMedia` and `renderStill`. Source frames use
`Composition`, `useCurrentFrame`, `delayRender`, `continueRender` and `staticFile`.
No timeline CSS animation, remote media or nondeterministic randomness.

## Direction and timing

960 × 800 (6:5), 24 fps, 432 frames, exactly 18 seconds, silent.

| Time | Action |
| --- | --- |
| 0–5 s | Three named, shape-coded Pi agents; request/answer slips pass through You. |
| 5–7 s | You moves out of the route; lines draw in and the circular Concourse station appears. Headline fades out then in, without overlapping text. |
| 7–17 s | Complete connected map, moving packets, “Connected. Without the copy-paste.” and “Back to your work”. |
| 17–18 s | A left-to-right architectural wipe restores the opening map. Last and first source frames are byte-identical. |

Palette: dark olive `#242820`, acid yellow `#dfff00`, lavender `#b9a4f5`,
orange `#ff8860`, warm white `#f2f0e7`. Original SVG arches echo the station
symbol. The poster is frame 264 (11 seconds), a complete connected state.

## Outputs and verification

Committed under `app/assets/images/`:

| Asset | Encoding | Verified size |
| --- | --- | ---: |
| `connection.mp4` | H.264, limited-range yuv420p, faststart | 414,546 bytes |
| `connection.webm` | VP9, limited-range yuv420p | 450,763 bytes |
| `connection-poster.webp` | WebP, quality 85 | 36,846 bytes |

The local render took 49.1 seconds on the author's machine. Encoding sizes and
runtime may vary slightly with ffmpeg/Chromium versions. The script fails when
a video reaches 4,000,000 bytes or the poster reaches 250,000 bytes.

Reviewed full-size before/transition/connected PNGs and a 350px-wide decoded MP4
frame. ffprobe verified 960 × 800, 24 fps, 18 seconds, expected codecs, yuv420p,
and exactly one video stream with no audio for both outputs. MP4 `moov` precedes
`mdat`. First and last source PNGs match byte-for-byte. Review images are local,
not deployment assets:

- `.build/before.png` — frame 60
- `.build/transition.png` — frame 144
- `.build/connected.png` — frame 264, poster source
- `.build/first.png`, `.build/last.png` — loop boundary

```sh
ffprobe -v error -show_streams -show_format ../../app/assets/images/connection.mp4
ffprobe -v error -show_streams -show_format ../../app/assets/images/connection.webm
cmp .build/first.png .build/last.png
# Optional 350px-wide review frame:
ffmpeg -y -ss 11 -i ../../app/assets/images/connection.mp4 \
  -frames:v 1 -vf scale=350:-1 .build/mobile.png
```

Website integration and reduced-motion handling belong to the parent workstream.
No website, auth, service, deployment or global configuration changes are included.

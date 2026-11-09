import React, {useEffect, useState} from 'react';
import {AbsoluteFill, Composition, continueRender, delayRender, registerRoot, staticFile, useCurrentFrame} from 'remotion';

const C = {bg: '#242820', ink: '#f2f0e7', acid: '#dfff00', purple: '#b9a4f5', orange: '#ff8860'};
const clamp = (n: number) => Math.min(1, Math.max(0, n));
const ease = (n: number) => { const t = clamp(n); return t * t * (3 - 2 * t); };
const mix = (a: number, b: number, t: number) => a + (b - a) * t;
const nodes = [
  {x: 160, y: 350, label: 'Builder', letter: 'B', color: C.acid, shape: 'square'},
  {x: 770, y: 330, label: 'Researcher', letter: 'R', color: C.purple, shape: 'diamond'},
  {x: 770, y: 590, label: 'Reviewer', letter: 'V', color: C.orange, shape: 'circle'},
];
const hub = {x: 455, y: 465};
const Text = ({x, y, children, size = 32, fill = C.ink, ...props}: any) => <text x={x} y={y} fill={fill} fontSize={size} {...props}>{children}</text>;

function Scene({frame}: {frame: number}) {
  const connected = ease((frame - 120) / 48);
  const personX = mix(hub.x, 160, connected);
  const personY = mix(hub.y, 636, connected);
  return <svg width="960" height="800" viewBox="0 0 960 800" style={{fontFamily: 'Figtree', background: C.bg}}>
    <defs>
      <radialGradient id="light"><stop stopColor={C.acid} stopOpacity=".07"/><stop offset="1" stopColor={C.acid} stopOpacity="0"/></radialGradient>
    </defs>
    <rect width="960" height="800" fill={C.bg}/>
    <ellipse cx="455" cy="465" rx="400" ry="310" fill="url(#light)" opacity={connected}/>
    <g fill="none" stroke={C.ink} strokeWidth="1" opacity=".045">
      {Array.from({length: 9}, (_, i) => <path key={i} d={`M ${20 + i * 46} 800 V 410 A ${460 - i * 46} ${360 - i * 34} 0 0 1 ${940 - i * 46} 410 V 800`}/>)}
    </g>
    <g fontFamily="Geist Mono" fontSize="21" letterSpacing="3" fill={C.ink}>
      <text x="58" y="62">CONCOURSE</text><text x="902" y="62" textAnchor="end" opacity=".6">PI AGENTS</text>
    </g>
    <path d="M58 84H902" stroke={C.ink} opacity=".2"/>
    <g opacity={1 - ease((frame - 120) / 18)} transform={`translate(0 ${-12 * ease((frame - 120) / 18)})`}>
      <Text x={58} y={151} size={52} fontWeight="600">Three agents.</Text>
      <Text x={58} y={212} size={52} fontWeight="600">You carry every message.</Text>
    </g>
    <g opacity={ease((frame - 142) / 26)} transform={`translate(0 ${12 * (1 - ease((frame - 142) / 26))})`}>
      <Text x={58} y={151} size={58} fontWeight="600">Connected.</Text>
      <Text x={58} y={212} size={52} fontWeight="500">Without the copy-paste.</Text>
    </g>
    {nodes.map((node, i) => {
      const path = `M ${node.x} ${node.y} L ${node.x > hub.x ? 620 : 275} ${node.y} L ${node.x > hub.x ? 555 : 390} ${hub.y} L ${hub.x} ${hub.y}`;
      // Both states use the same station geometry. Only the human relay changes.
      const points = [{x: node.x, y: node.y}, {x: node.x > hub.x ? 620 : 275, y: node.y}, {x: node.x > hub.x ? 555 : 390, y: hub.y}, hub];
      const at = (progress: number) => {
        const lengths = points.slice(1).map((p, k) => Math.hypot(p.x - points[k].x, p.y - points[k].y));
        let d = progress * lengths.reduce((a, b) => a + b, 0);
        for (let k = 0; k < lengths.length; k++) {
          if (d <= lengths[k] || k === lengths.length - 1) return {x: mix(points[k].x, points[k + 1].x, d / lengths[k]), y: mix(points[k].y, points[k + 1].y, d / lengths[k])};
          d -= lengths[k];
        }
        return hub;
      };
      const phase = ((frame + i * 36) % 108) / 108;
      const packet = at(i === 1 ? 1 - phase : phase);
      const slip = at(i === 1 ? 1 - ease(phase) : ease(phase));
      return <g key={node.label}>
        <path d={path} fill="none" stroke={C.ink} opacity={.22 * (1 - connected)} strokeWidth="3" strokeDasharray="5 12"/>
        <path d={path} fill="none" stroke={node.color} strokeWidth="7" strokeLinejoin="round" pathLength="1" strokeDasharray="1" strokeDashoffset={1 - connected} opacity={connected}/>
        <g opacity={(1 - ease((frame - 120) / 18)) * Math.sin(phase * Math.PI)} transform={`translate(${slip.x} ${slip.y}) rotate(${i === 1 ? -7 : 5})`}>
          <rect x="-64" y="-24" width="128" height="48" rx="4" fill={C.ink}/>
          <path d="M-54 -14h9v28h-9" stroke={node.color} strokeWidth="3"/>
          <Text x={4} y={8} size={23} fill={C.bg} textAnchor="middle" fontWeight="600">{i === 1 ? 'Answer' : 'Request'}</Text>
        </g>
        <g opacity={connected} transform={`translate(${packet.x} ${packet.y})`}>
          <circle r="15" fill={C.bg}/><rect x="-10" y="-7" width="20" height="14" rx="3" fill={C.ink}/>
        </g>
        <g transform={`translate(${node.x} ${node.y})`}>
          <circle r="51" fill={C.bg}/>
          {node.shape === 'square' ? <rect x="-33" y="-33" width="66" height="66" rx="8" fill={node.color}/> : node.shape === 'diamond' ? <rect x="-30" y="-30" width="60" height="60" rx="6" transform="rotate(45)" fill={node.color}/> : <circle r="36" fill={node.color}/>}
          <Text x={0} y={13} textAnchor="middle" size={36} fontWeight="700" fill={C.bg}>{node.letter}</Text>
          <Text x={0} y={85} textAnchor="middle" size={36} fontWeight="600">{node.label}</Text>
          <Text x={0} y={117} textAnchor="middle" size={21} fill={node.color} fontFamily="Geist Mono">Pi agent</Text>
        </g>
      </g>;
    })}
    <g opacity={connected} transform={`translate(${hub.x} ${hub.y}) scale(${.7 + connected * .3})`}>
      <circle r="81" fill={C.bg} stroke={C.acid} strokeWidth="2"/>
      <circle r="67" fill={C.acid}/>
      <path d="M-20 25V-7a20 20 0 0 1 40 0v32M-34 25h68" stroke={C.bg} strokeWidth="8" fill="none"/>
      <rect x="-109" y="94" width="218" height="49" rx="5" fill={C.bg}/>
      <Text x={0} y={129} textAnchor="middle" fill={C.acid} size={38} fontWeight="600">Concourse</Text>
    </g>
    <g transform={`translate(${personX} ${personY})`}>
      <circle r={mix(61, 36, connected)} fill={C.bg} stroke={C.ink} strokeWidth="2"/>
      <g transform={`scale(${mix(1, .7, connected)})`} fill="none" stroke={C.ink} strokeWidth="4" strokeLinecap="round">
        <circle cy="-15" r="11"/><path d="M-21 22v-3a21 21 0 0 1 42 0v3"/>
      </g>
      <Text x={0} y={99} size={34} textAnchor="middle" fontWeight="600" opacity={1 - ease(connected * 3)}>You</Text>
      <Text x={58} y={8} size={34} fontWeight="600" opacity={ease((connected - .7) / .3)}>You</Text>
    </g>
    <Text x={123} y={708} size={29} opacity={connected}>Back to your work</Text>
    <g fontFamily="Geist Mono" fontSize="19" letterSpacing="2" fill={C.ink} opacity=".5">
      <path d="M58 745H902" stroke={C.ink} opacity=".4"/>
      <text x="58" y="778">{connected > .5 ? '02 / CONNECTED' : '01 / THE HUMAN RELAY'}</text>
      <text x="902" y="778" textAnchor="end">MESSAGE → REPLY</text>
    </g>
  </svg>;
}

function Film() {
  const frame = useCurrentFrame();
  const [handle] = useState(() => delayRender('Load local typefaces'));
  useEffect(() => {
    Promise.all([
      new FontFace('Figtree', `url(${staticFile('figtree-latin-wght-normal.woff2')})`, {weight: '300 900'}).load(),
      new FontFace('Geist Mono', `url(${staticFile('geist-mono-latin-wght-normal.woff2')})`, {weight: '100 900'}).load(),
    ]).then(fonts => {fonts.forEach(font => document.fonts.add(font)); continueRender(handle);});
  }, [handle]);
  // A one-second architectural wipe returns to the exact opening frame, never black.
  const reset = ease((frame - 408) / 23);
  return <AbsoluteFill style={{background: C.bg}}>
    <AbsoluteFill><Scene frame={frame}/></AbsoluteFill>
    {reset > 0 && <AbsoluteFill style={{clipPath: `inset(0 ${(1 - reset) * 100}% 0 0)`}}><Scene frame={0}/></AbsoluteFill>}
  </AbsoluteFill>;
}
registerRoot(() => <Composition id="Connection" component={Film} width={960} height={800} fps={24} durationInFrames={432}/>);

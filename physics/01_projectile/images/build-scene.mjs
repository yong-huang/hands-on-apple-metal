#!/usr/bin/env node
// 物理线图三件套的渲染端：projectile.scene.json（图源）→ projectile.svg（双主题静态教学场景）。
// 确定性生成：同一图源永远得到同一 SVG；RK4 数值口径与 ../projectile.swift 逐字一致（dt=1e-3 s）。
// 用法: node build-scene.mjs
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const scene = JSON.parse(readFileSync(join(here, 'projectile.scene.json'), 'utf8'));
const P = scene.physics, W = scene.world, C = scene.canvas, INS = scene.inset, AN = scene.annotations;
const rad = (d) => (d * Math.PI) / 180;

// ---- RK4：与 projectile.swift 同一数值口径（二次阻力 F=-c|v|v，落地线性插值）----
function accel(vx, vy, c) {
  const s = Math.hypot(vx, vy);
  return [(-c * s * vx) / P.mass, -P.g - (c * s * vy) / P.mass];
}
function simulate(c, angleDeg = P.angleDeg, v0 = P.v0, dt = P.dt) {
  let s = [0, 0, v0 * Math.cos(rad(angleDeg)), v0 * Math.sin(rad(angleDeg))];
  const pts = [[0, 0, s[2], s[3]]];
  let t = 0, hMax = 0, i = 0;
  const f = (u) => {
    const a = accel(u[2], u[3], c);
    return [u[2], u[3], a[0], a[1]];
  };
  while (t < 500) {
    const prev = s;
    const k1 = f(s), k2 = f(s.map((v, j) => v + 0.5 * dt * k1[j])),
          k3 = f(s.map((v, j) => v + 0.5 * dt * k2[j])), k4 = f(s.map((v, j) => v + dt * k3[j]));
    s = s.map((v, j) => v + (dt / 6) * (k1[j] + 2 * k2[j] + 2 * k3[j] + k4[j]));
    t += dt;
    hMax = Math.max(hMax, s[1]);
    if (++i % 20 === 0) pts.push([s[0], s[1], s[2], s[3]]);
    if (s[1] < 0) {
      const fr = prev[1] / (prev[1] - s[1]);
      const range = prev[0] + fr * (s[0] - prev[0]);
      pts.push([range, 0, s[2], s[3]]);
      return { range, hMax, flightTime: t - dt + fr * dt, pts };
    }
  }
  throw new Error('积分 500 s 未落地');
}
// 按时刻取采样点（样本间隔 0.02 s）：用于等时标记与速度矢量
function stateAt(traj, t) {
  return traj.pts[Math.min(Math.round(t / 0.02), traj.pts.length - 1)];
}
function bestAngle(c) {
  let best = { a: P.sweep.angleMin, r: 0 };
  for (let a = P.sweep.angleMin; a <= P.sweep.angleMax + 1e-9; a += P.sweep.step) {
    const r = simulate(c, a, P.v0, P.sweep.dt).range;
    if (r > best.r) best = { a, r };
  }
  return best;
}

// ---- 主图坐标：世界（米）→ 画布（px） ----
const { width, height, margin } = C;
const plotX0 = margin.left, plotX1 = width - margin.right;
const plotY1 = height - margin.bottom;                        // 地面所在像素行
const sx = (plotX1 - plotX0) / W.xMax, sy = plotY1 / W.yMax;
const X = (m) => +(plotX0 + m * sx).toFixed(1);
const Y = (m) => +(plotY1 - m * sy).toFixed(1);
const path = (pts, tf) => pts.map((p, i) => `${i ? 'L' : 'M'}${tf(p[0], p[1])}`).join('');

const vac = simulate(0), drg = simulate(P.dragC);
console.log(`真空射程 ${vac.range.toFixed(2)} m（峰值 ${vac.hMax.toFixed(1)} m）`);
console.log(`阻力射程 ${drg.range.toFixed(2)} m（峰值 ${drg.hMax.toFixed(1)} m）`);

// ---- 内嵌小图：射程–射角曲线，峰值随阻力左移（本实验的教学题眼）----
const ix0 = INS.x, iy0 = INS.y, ix1 = INS.x + INS.width, iy1 = INS.y + INS.height;
const isx = (a) => +(ix0 + ((a - INS.xMin) / (INS.xMax - INS.xMin)) * INS.width).toFixed(1);
const isy = (r) => +(iy1 - (r / INS.yMax) * INS.height).toFixed(1);
const sweepColors = ['muted', 'accent', 'drag', 'alert'];
const sweepSvg = [], peaks = [];
P.sweepCurves.forEach((c, k) => {
  const pts = [];
  for (let a = INS.xMin; a <= INS.xMax + 1e-9; a += 0.5) pts.push([a, simulate(c, a, P.v0, P.sweep.dt).range]);
  const dash = c === 0 ? ' stroke-dasharray="6 4"' : '';
  sweepSvg.push(`<path class="stroke-${sweepColors[k]}" d="${path(pts, (a, r) => `${isx(a)},${isy(r)}`)}" fill="none"${dash}/>`);
  peaks.push({ c, ...bestAngle(c) });
});
console.log('峰值：' + peaks.map((p) => `c=${p.c} → ${p.a.toFixed(2)}°`).join('，'));

// ---- 主图教学图层：包络 / 等时标记 / 速度矢量 ----
const envSvg = [];
for (let x = 0; x <= W.xMax; x += W.xMax / 240) {
  const y = P.v0 * P.v0 / (2 * P.g) - P.g * x * x / (2 * P.v0 * P.v0);
  if (y < 0) break;
  envSvg.push([x, y]);
}
const envPath = envSvg.map((p, i) => `${i ? 'L' : 'M'}${X(p[0])},${Y(p[1])}`).join('');
const vecSvg = [];
function velArrow(traj, f, cls) {
  const p = stateAt(traj, traj.flightTime * f);
  const x0 = X(p[0]), y0 = Y(p[1]), x1 = x0 + p[2] * 2, y1 = y0 - p[3] * 2;
  const th = Math.atan2(y1 - y0, x1 - x0);
  const hx = x1 + 3 * Math.cos(th), hy = y1 + 3 * Math.sin(th);
  const l1 = [x1 - 9 * Math.cos(th - 0.42), y1 - 9 * Math.sin(th - 0.42)];
  const l2 = [x1 - 9 * Math.cos(th + 0.42), y1 - 9 * Math.sin(th + 0.42)];
  return `<line class="${cls}" x1="${x0.toFixed(1)}" y1="${y0.toFixed(1)}" x2="${x1.toFixed(1)}" y2="${y1.toFixed(1)}" stroke-width="2.5"/>
  <polygon points="${hx.toFixed(1)},${hy.toFixed(1)} ${l1[0].toFixed(1)},${l1[1].toFixed(1)} ${l2[0].toFixed(1)},${l2[1].toFixed(1)}" fill="var(--${cls.replace('stroke-', '')})"/>`;
}
const markSvg = [];
const tEnd = Math.min(vac.flightTime, drg.flightTime) - 1e-6;
for (let t = 0.5; t < tEnd; t += 0.5) {
  const a = stateAt(vac, t), b = stateAt(drg, t);
  markSvg.push(`<line class="stroke-muted" x1="${X(a[0])}" y1="${Y(a[1])}" x2="${X(b[0])}" y2="${Y(b[1])}" stroke-dasharray="2 4" opacity="0.7"/>`);
  markSvg.push(`<circle cx="${X(a[0])}" cy="${Y(a[1])}" r="3.5" fill="none" stroke="var(--vacuum)" stroke-width="1.5"/>`);
  markSvg.push(`<circle cx="${X(b[0])}" cy="${Y(b[1])}" r="3.5" fill="none" stroke="var(--drag)" stroke-width="1.5"/>`);
  markSvg.push(`<text class="muted fs10" x="${X((a[0] + b[0]) / 2)}" y="${Y((a[1] + b[1]) / 2) - 7}" text-anchor="middle">${t.toFixed(1)}s</text>`);
}

// ---- 组装双主题 SVG（prefers-color-scheme 切换） ----
const tD = scene.themes.dark, tL = scene.themes.light;
const tickSvg = [];
for (let x = W.tickEvery; x < W.xMax; x += W.tickEvery) {
  tickSvg.push(`<line class="stroke-ground" x1="${X(x)}" y1="${Y(0)}" x2="${X(x)}" y2="${Y(0) + 8}"/>`);
  tickSvg.push(`<text class="muted fs11" x="${X(x)}" y="${Y(0) + 22}" text-anchor="middle">${x}</text>`);
}
const cssVars = (t) => `--bg:${t.bg};--grid:${t.grid};--ground:${t.ground};--text:${t.text};--muted:${t.muted};--vacuum:${t.vacuum};--drag:${t.drag};--accent:${t.accent};--alert:${t.alert}`;
const css = `
  :root { ${cssVars(tD)} }
  @media (prefers-color-scheme: light) { :root { ${cssVars(tL)} } }
  text { fill: var(--text); font: 14px -apple-system, 'PingFang SC', sans-serif; }
  .fs10 { font-size: 10px; } .fs11 { font-size: 11px; } .fs12 { font-size: 12px; } .fs16 { font-size: 16px; }
  .muted { fill: var(--muted); }
  .stroke-ground { stroke: var(--ground); } .stroke-grid { stroke: var(--grid); }
  .stroke-vacuum { stroke: var(--vacuum); } .stroke-drag { stroke: var(--drag); }
  .stroke-accent { stroke: var(--accent); } .stroke-alert { stroke: var(--alert); }
  .stroke-muted { stroke: var(--muted); }
`;
const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" role="img" aria-label="${scene.title}">
<style>${css}</style>
<rect width="${width}" height="${height}" fill="var(--bg)"/>
<text x="${plotX0}" y="36" class="fs16">${scene.title}</text>
<text class="muted fs12" x="${plotX0}" y="58">${AN.caption}</text>
<text class="muted fs12" x="${plotX0}" y="76">${AN.terminal}</text>
<line class="stroke-ground" x1="${plotX0 - 6}" y1="${Y(0)}" x2="${plotX1}" y2="${Y(0)}"/>
${tickSvg.join('\n')}
<path class="stroke-accent" d="${envPath}" fill="none" stroke-width="1.5" stroke-dasharray="3 5"/>
<text class="stroke-accent" x="${X(32) + 6}" y="${Y(P.v0 * P.v0 / (2 * P.g) - P.g * 32 * 32 / (2 * P.v0 * P.v0)) + 4}" font-size="12" stroke="none" fill="var(--accent)">${AN.envelope}</text>
<path class="stroke-vacuum" d="${path(vac.pts, (a, b) => `${X(a)},${Y(b)}`)}" fill="none" stroke-width="2" stroke-dasharray="7 5"/>
<path class="stroke-drag" d="${path(drg.pts, (a, b) => `${X(a)},${Y(b)}`)}" fill="none" stroke-width="2.5"/>
${markSvg.join('\n')}
${velArrow(vac, 0.3, 'stroke-vacuum')}
${velArrow(vac, 0.6, 'stroke-vacuum')}
${velArrow(vac, 0.85, 'stroke-vacuum')}
${velArrow(drg, 0.3, 'stroke-drag')}
${velArrow(drg, 0.6, 'stroke-drag')}
${velArrow(drg, 0.85, 'stroke-drag')}
<circle cx="${X(vac.range)}" cy="${Y(0)}" r="3.5" fill="var(--vacuum)"/>
<circle cx="${X(drg.range)}" cy="${Y(0)}" r="3.5" fill="var(--drag)"/>
<text x="${X(vac.range)}" y="${Y(0) + 40}" text-anchor="middle" font-size="12" fill="var(--vacuum)">${AN.vacuumLanding}</text>
<text x="${X(drg.range)}" y="${Y(0) + 58}" text-anchor="middle" font-size="12" fill="var(--drag)">${AN.dragLanding}</text>
<line class="stroke-muted" x1="${X(drg.range)}" y1="${Y(0) + 8}" x2="${X(vac.range)}" y2="${Y(0) + 8}" stroke-dasharray="4 4"/>
<text class="muted fs12" x="${X((drg.range + vac.range) / 2)}" y="${Y(0) - 14}" text-anchor="middle">${AN.loss}</text>
<line class="stroke-drag" x1="${X(0)}" y1="${Y(0)}" x2="${X(0) + 90 * Math.cos(rad(P.angleDeg))}" y2="${Y(0) - 90 * Math.sin(rad(P.angleDeg))}" stroke-width="2"/>
<text class="fs12" x="${X(0) + 40}" y="${Y(0) - 20}" fill="var(--drag)">${AN.launch}</text>
<text class="muted fs11" x="${plotX0}" y="${height - 10}">${AN.legend}</text>
<text class="muted fs11" x="${plotX1}" y="${height - 10}" text-anchor="end">${AN.footer}</text>
<rect class="stroke-grid" x="${ix0}" y="${iy0}" width="${INS.width}" height="${INS.height}" fill="none"/>
${sweepSvg.join('\n')}
<text class="muted fs12" x="${ix0 + 8}" y="${iy1 - 10}">${INS.title}</text>
<text class="fs10" x="${ix1 - 8}" y="${iy1 - 10}" text-anchor="end">c：<tspan class="muted">0（虚线）</tspan><tspan class="stroke-accent" fill="var(--accent)"> 0.002</tspan><tspan fill="var(--drag)"> 0.005</tspan><tspan fill="var(--alert)"> 0.010</tspan></text>
<circle cx="${isx(peaks[0].a)}" cy="${isy(peaks[0].r)}" r="3" fill="var(--muted)"/>
<text class="muted fs11" x="${isx(peaks[0].a)}" y="${isy(peaks[0].r) - 8}" text-anchor="middle">45.00°</text>
<circle cx="${isx(peaks[3].a)}" cy="${isy(peaks[3].r)}" r="3" fill="var(--alert)"/>
<text class="muted fs11" x="${isx(peaks[3].a) + 8}" y="${isy(peaks[3].r) + 16}">${AN.insetNote}</text>
</svg>
`;
writeFileSync(join(here, 'projectile.svg'), svg);
console.log(`已生成 projectile.svg（${svg.length} 字节）`);

import type { Dir, MonsterKind } from "@/lib/game/types";

/*
 * The figures, drawn with canvas paths in cell units around a centre: the
 * digger in his suit and helmet, Pookas in their goggles, Fygars with their
 * wings, the rocks and their rubble, a flame, a flower. `px` is device pixels
 * per cell, for the glows — the canvas never scales a shadow's blur.
 */

type Ctx = CanvasRenderingContext2D;

/** A small hash for steady per-thing wobble: the same input, the same output, in [0, 1). */
export function noise(n: number): number {
  const s = Math.sin(n * 12.9898) * 43758.5453;
  return s - Math.floor(s);
}

function circle(ctx: Ctx, x: number, y: number, r: number): void {
  ctx.beginPath();
  ctx.arc(x, y, r, 0, Math.PI * 2);
}

function ellipse(ctx: Ctx, x: number, y: number, rx: number, ry: number): void {
  ctx.beginPath();
  ctx.ellipse(x, y, rx, ry, 0, 0, Math.PI * 2);
}

function rounded(ctx: Ctx, x: number, y: number, w: number, h: number, r: number): void {
  ctx.beginPath();
  ctx.roundRect(x, y, w, h, r);
}

/** Turn the drawing so local +x is the way it faces; going up or down, the head stays on the side last faced. */
function orient(ctx: Ctx, facing: Dir, side: -1 | 1): void {
  if (facing === "left") {
    ctx.scale(-1, 1);
  } else if (facing === "up" || facing === "down") {
    ctx.rotate(facing === "up" ? -Math.PI / 2 : Math.PI / 2);
    if ((facing === "up") === (side > 0)) ctx.scale(1, -1);
  }
}

export interface DiggerPose {
  facing: Dir;
  side: -1 | 1;
  /** Sub-steps walked, for the stride. */
  steps: number;
  moving: boolean;
  /** Working the pump: the arms jerk. */
  pumping: boolean;
  t: number;
}

/** The digger: white suit, blue boots, a tank on the back and the pump's nozzle out front. */
export function drawDigger(ctx: Ctx, x: number, y: number, pose: DiggerPose, px: number): void {
  ctx.save();
  ctx.translate(x, y);
  orient(ctx, pose.facing, pose.side);
  const stride = pose.moving ? (Math.floor(pose.steps / 3) % 2 === 0 ? 1 : -1) : 0;
  const jerk = pose.pumping ? Math.sin(pose.t * 0.8) * 0.03 : 0;

  ctx.fillStyle = "#0284c7";
  rounded(ctx, -0.18 + stride * 0.04, 0.19, 0.13, 0.17, 0.05);
  ctx.fill();
  rounded(ctx, 0.03 - stride * 0.04, 0.19, 0.13, 0.17, 0.05);
  ctx.fill();

  ctx.fillStyle = "#38bdf8";
  rounded(ctx, -0.37, -0.1, 0.14, 0.3, 0.06);
  ctx.fill();
  ctx.fillStyle = "rgba(224, 242, 254, 0.75)";
  rounded(ctx, -0.34, -0.07, 0.035, 0.22, 0.02);
  ctx.fill();

  ctx.shadowColor = "#22d3ee";
  ctx.shadowBlur = px * 0.22;
  ctx.fillStyle = "#f8fafc";
  rounded(ctx, -0.25, -0.08, 0.43, 0.33, 0.12);
  ctx.fill();
  circle(ctx, 0, -0.2, 0.18);
  ctx.fill();
  ctx.shadowBlur = 0;

  ctx.fillStyle = "#0ea5e9";
  ctx.fillRect(-0.25, 0.09, 0.43, 0.05);
  ctx.strokeStyle = "#0ea5e9";
  ctx.lineWidth = 0.04;
  ctx.beginPath();
  ctx.arc(0, -0.2, 0.18, Math.PI * 1.08, Math.PI * 1.6);
  ctx.stroke();

  // The visor, dark glass with a glint.
  ctx.fillStyle = "#0f172a";
  rounded(ctx, 0.0, -0.29, 0.17, 0.15, 0.06);
  ctx.fill();
  ctx.fillStyle = "#67e8f9";
  rounded(ctx, 0.05, -0.26, 0.09, 0.035, 0.017);
  ctx.fill();

  ctx.fillStyle = "#cbd5e1";
  rounded(ctx, 0.04 + jerk, -0.01, 0.26, 0.08, 0.04);
  ctx.fill();
  ctx.fillStyle = "#e0f2fe";
  rounded(ctx, 0.27 + jerk, -0.025, 0.1, 0.11, 0.03);
  ctx.fill();
  ctx.restore();
}

export interface MonsterPose {
  side: -1 | 1;
  steps: number;
  /** 0 normal; each size bigger on the way to popping. */
  inflate: number;
  t: number;
  /** A Fygar working up a breath of fire. */
  hot?: boolean;
}

/** A Pooka: a round red body in yellow goggles, on little feet. It swells with each pump. */
export function drawPooka(ctx: Ctx, x: number, y: number, pose: MonsterPose, px: number): void {
  const s = 1 + 0.22 * pose.inflate;
  ctx.save();
  ctx.translate(x, y);
  ctx.scale(pose.side, 1);
  if (pose.inflate === 0) {
    const k = Math.floor(pose.steps / 3) % 2 === 0 ? 1 : -1;
    ctx.fillStyle = "#fda4af";
    ellipse(ctx, -0.14 + k * 0.03, 0.33, 0.09, 0.055);
    ctx.fill();
    ellipse(ctx, 0.13 - k * 0.03, 0.33, 0.09, 0.055);
    ctx.fill();
  }
  const R = 0.34 * s;
  const body = ctx.createRadialGradient(-0.12 * s, -0.12 * s, 0.02, 0, 0.02, R);
  body.addColorStop(0, pose.inflate >= 3 ? "#ffffff" : "#ffe4e6");
  body.addColorStop(0.4, "#fb7185");
  body.addColorStop(1, "#be123c");
  ctx.shadowColor = "#fb7185";
  ctx.shadowBlur = px * 0.3;
  ctx.fillStyle = body;
  circle(ctx, 0, 0.02, R);
  ctx.fill();
  ctx.shadowBlur = 0;

  ctx.fillStyle = "#facc15";
  rounded(ctx, -0.09 * s, -0.17 * s, 0.4 * s, 0.21 * s, 0.1 * s);
  ctx.fill();
  const look = pose.inflate > 0 ? Math.sin(pose.t * 0.6) * 0.02 : 0.016;
  for (const ex of [0.03, 0.2]) {
    ctx.fillStyle = "#ffffff";
    circle(ctx, ex * s, -0.065 * s, 0.07 * s);
    ctx.fill();
    ctx.fillStyle = "#0f172a";
    circle(ctx, ex * s + look * s, -0.065 * s, 0.034 * s);
    ctx.fill();
  }
  ctx.restore();
}

/** A Fygar: a green dragon with a wing on its back. Working up a breath it flashes hot. */
export function drawFygar(ctx: Ctx, x: number, y: number, pose: MonsterPose, px: number): void {
  const s = 1 + 0.22 * pose.inflate;
  const hot = pose.hot === true && Math.floor(pose.t / 4) % 2 === 0;
  ctx.save();
  ctx.translate(x, y);
  ctx.scale(pose.side, 1);

  const flap = pose.inflate === 0 ? Math.sin(pose.steps * 0.6) * 0.07 : 0;
  ctx.fillStyle = "rgba(134, 239, 172, 0.85)";
  ctx.beginPath();
  ctx.moveTo(-0.08 * s, -0.12 * s);
  ctx.lineTo(-0.34 * s, (-0.4 - flap) * s);
  ctx.lineTo(-0.3 * s, -0.06 * s);
  ctx.closePath();
  ctx.fill();

  if (pose.inflate === 0) {
    const k = Math.floor(pose.steps / 3) % 2 === 0 ? 1 : -1;
    ctx.fillStyle = "#16a34a";
    rounded(ctx, -0.2 + k * 0.03, 0.22, 0.11, 0.13, 0.04);
    ctx.fill();
    rounded(ctx, 0.04 - k * 0.03, 0.22, 0.11, 0.13, 0.04);
    ctx.fill();
  }

  const body = ctx.createRadialGradient(0, -0.1 * s, 0.02, 0, 0, 0.42 * s);
  body.addColorStop(0, hot ? "#fefce8" : pose.inflate >= 3 ? "#ffffff" : "#dcfce7");
  body.addColorStop(0.45, hot ? "#fde047" : "#4ade80");
  body.addColorStop(1, hot ? "#ca8a04" : "#15803d");
  ctx.shadowColor = hot ? "#fde047" : "#4ade80";
  ctx.shadowBlur = px * (hot ? 0.5 : 0.3);
  ctx.fillStyle = body;
  ellipse(ctx, -0.05 * s, 0.04 * s, 0.3 * s, 0.27 * s);
  ctx.fill();
  ellipse(ctx, 0.22 * s, -0.05 * s, 0.17 * s, 0.14 * s);
  ctx.fill();
  ctx.shadowBlur = 0;

  // Spines along the back.
  ctx.fillStyle = hot ? "#fef08a" : "#bbf7d0";
  for (const sx of [-0.22, -0.08]) {
    ctx.beginPath();
    ctx.moveTo((sx - 0.05) * s, -0.2 * s);
    ctx.lineTo(sx * s, -0.3 * s);
    ctx.lineTo((sx + 0.05) * s, -0.21 * s);
    ctx.closePath();
    ctx.fill();
  }

  ctx.fillStyle = "#ffffff";
  circle(ctx, 0.2 * s, -0.12 * s, 0.062 * s);
  ctx.fill();
  ctx.fillStyle = "#0f172a";
  circle(ctx, 0.22 * s, -0.12 * s, 0.03 * s);
  ctx.fill();
  ctx.fillStyle = "#14532d";
  circle(ctx, 0.35 * s, -0.07 * s, 0.018 * s);
  ctx.fill();
  if (pose.hot) {
    // The mouth glowing open.
    ctx.fillStyle = hot ? "#fb923c" : "#7c2d12";
    ctx.beginPath();
    ctx.moveTo(0.18 * s, 0.02 * s);
    ctx.lineTo(0.39 * s, -0.01 * s);
    ctx.lineTo(0.37 * s, 0.06 * s);
    ctx.closePath();
    ctx.fill();
  }
  ctx.restore();
}

/** A monster drifting through the dirt: only its eyes, and a faint shell where its body would be. */
export function drawEyes(ctx: Ctx, x: number, y: number, kind: MonsterKind, side: -1 | 1, t: number, px: number): void {
  ctx.save();
  ctx.translate(x, y + Math.sin(t * 0.15) * 0.04);
  ctx.scale(side, 1);
  ctx.strokeStyle = kind === "pooka" ? "rgba(251, 113, 133, 0.4)" : "rgba(74, 222, 128, 0.4)";
  ctx.lineWidth = 0.03;
  ctx.setLineDash([0.07, 0.07]);
  circle(ctx, 0, 0.02, 0.32);
  ctx.stroke();
  ctx.setLineDash([]);
  ctx.shadowColor = "#e0f2fe";
  ctx.shadowBlur = px * 0.3;
  for (const ex of [-0.04, 0.16]) {
    if (kind === "pooka") {
      ctx.fillStyle = "#facc15";
      circle(ctx, ex, -0.04, 0.1);
      ctx.fill();
    }
    ctx.fillStyle = "#ffffff";
    circle(ctx, ex, -0.04, 0.07);
    ctx.fill();
  }
  ctx.shadowBlur = 0;
  ctx.fillStyle = "#0f172a";
  for (const ex of [-0.04, 0.16]) {
    circle(ctx, ex + 0.02, -0.04, 0.034);
    ctx.fill();
  }
  ctx.restore();
}

/** The points of a rock's outline, the same every time for the same rock. */
function rockShape(seed: number, radius: number): [number, number][] {
  const pts: [number, number][] = [];
  for (let i = 0; i < 10; i++) {
    const a = (i / 10) * Math.PI * 2;
    const r = radius * (0.84 + 0.16 * noise(seed * 7.31 + i));
    pts.push([Math.cos(a) * r, Math.sin(a) * r * 0.92]);
  }
  return pts;
}

/** A boulder with a violet edge, tilted when it wobbles. */
export function drawRock(ctx: Ctx, x: number, y: number, seed: number, tilt: number, px: number): void {
  ctx.save();
  ctx.translate(x, y);
  ctx.rotate(tilt);
  const pts = rockShape(seed, 0.44);
  ctx.beginPath();
  pts.forEach(([px2, py2], i) => (i === 0 ? ctx.moveTo(px2, py2) : ctx.lineTo(px2, py2)));
  ctx.closePath();
  const fill = ctx.createLinearGradient(-0.3, -0.35, 0.3, 0.4);
  fill.addColorStop(0, "#b4bfd3");
  fill.addColorStop(0.5, "#56627a");
  fill.addColorStop(1, "#1e293b");
  ctx.shadowColor = "#a78bfa";
  ctx.shadowBlur = px * 0.25;
  ctx.fillStyle = fill;
  ctx.fill();
  ctx.shadowBlur = 0;
  ctx.strokeStyle = "#c4b5fd";
  ctx.lineWidth = 0.035;
  ctx.stroke();
  ctx.strokeStyle = "rgba(241, 245, 249, 0.6)";
  ctx.lineWidth = 0.04;
  ctx.beginPath();
  ctx.arc(-0.05, -0.05, 0.25, Math.PI * 1.05, Math.PI * 1.45);
  ctx.stroke();
  ctx.strokeStyle = "rgba(15, 23, 42, 0.65)";
  ctx.lineWidth = 0.025;
  ctx.beginPath();
  ctx.moveTo(0.05, -0.12);
  ctx.lineTo(0.13, 0.03);
  ctx.lineTo(0.06, 0.18);
  ctx.stroke();
  ctx.restore();
}

/** A rock breaking up where it landed: chips flying apart and dropping, fading by `f` (0 to 1). */
export function drawRubble(ctx: Ctx, x: number, y: number, seed: number, f: number): void {
  ctx.save();
  ctx.globalAlpha = Math.max(0, 1 - f);
  for (let i = 0; i < 7; i++) {
    const a = (i / 7) * Math.PI * 2 + noise(seed + i) * 0.6;
    const out = 0.12 + f * 0.45;
    const cx = x + Math.cos(a) * out;
    const cy = y + Math.sin(a) * out * 0.5 + f * f * 0.45;
    const size = 0.12 * (1 - f * 0.5);
    ctx.fillStyle = i % 2 === 0 ? "#94a3b8" : "#64748b";
    ctx.strokeStyle = "rgba(196, 181, 253, 0.8)";
    ctx.lineWidth = 0.02;
    ctx.beginPath();
    ctx.moveTo(cx - size, cy);
    ctx.lineTo(cx - size * 0.2, cy - size * 0.9);
    ctx.lineTo(cx + size, cy - size * 0.1);
    ctx.lineTo(cx + size * 0.3, cy + size * 0.8);
    ctx.closePath();
    ctx.fill();
    ctx.stroke();
  }
  ctx.restore();
}

/** A Fygar's breath: a tapering, flickering tongue of fire `len` cells long, out of the snout. */
export function drawFlame(ctx: Ctx, x: number, y: number, dir: -1 | 1, len: number, t: number, px: number): void {
  if (len <= 0) return;
  ctx.save();
  ctx.translate(x + dir * 0.32, y - 0.04);
  ctx.scale(dir, 1);
  const flick = Math.sin(t * 0.9) * 0.05;
  const outer = ctx.createLinearGradient(0, 0, len, 0);
  outer.addColorStop(0, "#fff7ed");
  outer.addColorStop(0.25, "#fde047");
  outer.addColorStop(0.65, "#fb923c");
  outer.addColorStop(1, "rgba(239, 68, 68, 0.2)");
  ctx.shadowColor = "#f97316";
  ctx.shadowBlur = px * 0.5;
  ctx.fillStyle = outer;
  ctx.beginPath();
  ctx.moveTo(0, -0.08);
  ctx.quadraticCurveTo(len * 0.45, -0.36 - flick, len, -0.05);
  ctx.quadraticCurveTo(len * 1.05, 0, len, 0.05);
  ctx.quadraticCurveTo(len * 0.45, 0.36 + flick, 0, 0.08);
  ctx.closePath();
  ctx.fill();
  ctx.shadowBlur = 0;
  ctx.fillStyle = "rgba(255, 251, 235, 0.85)";
  ctx.beginPath();
  ctx.moveTo(0, -0.04);
  ctx.quadraticCurveTo(len * 0.3, -0.14 + flick, len * 0.62, 0);
  ctx.quadraticCurveTo(len * 0.3, 0.14 - flick, 0, 0.04);
  ctx.closePath();
  ctx.fill();
  ctx.restore();
}

/** A flower standing on the ground line at (x, baseY): one marks each round, a big one each ten. */
export function drawFlower(ctx: Ctx, x: number, baseY: number, big: boolean): void {
  const s = big ? 1.45 : 1;
  ctx.save();
  ctx.translate(x, baseY);
  ctx.strokeStyle = "#4ade80";
  ctx.lineWidth = 0.035;
  ctx.beginPath();
  ctx.moveTo(0, 0);
  ctx.quadraticCurveTo(0.03 * s, -0.12 * s, 0, -0.25 * s);
  ctx.stroke();
  ctx.fillStyle = "#22c55e";
  ellipse(ctx, 0.05 * s, -0.09 * s, 0.05 * s, 0.022 * s);
  ctx.fill();
  const cy = -0.3 * s;
  ctx.fillStyle = big ? "#fde68a" : "#f9a8d4";
  for (let i = 0; i < 5; i++) {
    const a = (i / 5) * Math.PI * 2 - Math.PI / 2;
    circle(ctx, Math.cos(a) * 0.07 * s, cy + Math.sin(a) * 0.07 * s, 0.05 * s);
    ctx.fill();
  }
  ctx.fillStyle = big ? "#f97316" : "#facc15";
  circle(ctx, 0, cy, 0.042 * s);
  ctx.fill();
  ctx.restore();
}

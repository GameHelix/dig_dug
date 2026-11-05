import { DELTA, position } from "@/lib/game/board";
import {
  COLS,
  DEATH_TICKS,
  INFLATE_MAX,
  LAYER_ROWS,
  LAYERS,
  POP_TICKS,
  ROCK_CRUMBLE_TICKS,
  ROWS,
  SUB,
  TICK_HZ,
  VEGGIES,
} from "@/lib/game/constants";
import type { Game } from "@/lib/game/engine";
import { cellOf, colOf, layerOf, rowOf } from "@/lib/game/field";
import { flameReach } from "@/lib/game/monsters";
import type { Monster, Rock } from "@/lib/game/types";
import type { Run } from "@/lib/run";
import { drawDigger, drawEyes, drawFlame, drawFlower, drawFygar, drawPooka, drawRock, drawRubble, noise } from "./sprites";

/*
 * Draws a run on a 2D canvas. The sky and the four layers of dirt go once
 * into a cached layer, rebuilt for each round; the tunnels are paths rebuilt
 * whenever the digging changes them; every frame then lays the vegetable,
 * the monsters, the player, the rocks, the flames, the harpoon, the ghosts
 * and the passing flashes over them. Everything is drawn in cell units
 * through one transform, the whole field always in view.
 */

const C = {
  bg: "#070610",
  tunnel: "#06040d",
  skyTop: "#0b1033",
  skyLow: "#1d1040",
  star: "rgba(226, 232, 240, 0.75)",
  grass: "#34d399",
  harpoon: "#e0f2fe",
  harpoonGlow: "#22d3ee",
  points: "#fde68a",
  hurry: "251, 113, 133",
};

/** The four layers of dirt, top to bottom: fill, specks and the glowing rim of a tunnel cut through them. */
const DIRT = [
  { top: "#4a2508", bottom: "#341805", speck: "rgba(251, 191, 36, 0.32)", rim: "rgba(251, 146, 60, 0.85)" },
  { top: "#4a1033", bottom: "#350a24", speck: "rgba(244, 114, 182, 0.3)", rim: "rgba(244, 114, 182, 0.85)" },
  { top: "#2e1560", bottom: "#200d45", speck: "rgba(167, 139, 250, 0.32)", rim: "rgba(167, 139, 250, 0.85)" },
  { top: "#0d2c55", bottom: "#081d3b", speck: "rgba(56, 189, 248, 0.32)", rim: "rgba(56, 189, 248, 0.85)" },
] as const;

/** Half-widths of a tunnel: its glowing rim, and the open space inside it. */
const RIM = 0.47;
const HOLE = 0.41;

const BURST_TICKS = 26;
const POINTS_TICKS = 70;

const TINT = {
  pooka: ["#fb7185", "#fecdd3"],
  fygar: ["#4ade80", "#bbf7d0"],
  veg: ["#fbbf24", "#fef3c7"],
} as const;

interface Tunnels {
  key: string;
  rims: Path2D[];
  holes: Path2D;
}

export class FieldRenderer {
  private readonly canvas: HTMLCanvasElement;
  private readonly ctx: CanvasRenderingContext2D;
  private readonly layer: HTMLCanvasElement;
  private layerKey = "";
  private tunnels: Tunnels | null = null;
  private dpr = 1;
  private cssW = 0;
  private cssH = 0;
  /** CSS pixels per cell. */
  private tile = 0;
  /** The field's top-left corner, in CSS pixels: it sits centred. */
  private ox = 0;
  private oy = 0;
  private readonly reducedMotion: boolean;

  constructor(canvas: HTMLCanvasElement) {
    this.canvas = canvas;
    const ctx = canvas.getContext("2d");
    if (!ctx) throw new Error("2D canvas unavailable");
    this.ctx = ctx;
    this.layer = document.createElement("canvas");
    this.reducedMotion =
      typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches === true;
  }

  resize(cssW: number, cssH: number, dpr: number): void {
    this.cssW = Math.max(1, cssW);
    this.cssH = Math.max(1, cssH);
    this.dpr = dpr;
    this.canvas.width = Math.round(this.cssW * dpr);
    this.canvas.height = Math.round(this.cssH * dpr);
    this.tile = Math.min(this.cssW / COLS, this.cssH / ROWS);
    this.ox = (this.cssW - this.tile * COLS) / 2;
    this.oy = (this.cssH - this.tile * ROWS) / 2;
    this.layerKey = "";
  }

  /** Device pixels per cell. */
  private get px(): number {
    return this.tile * this.dpr;
  }

  draw(run: Run, now: number): void {
    if (this.tile <= 0) return;
    const g = run.game;
    const { ctx, dpr } = this;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.fillStyle = C.bg;
    ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);

    this.ensureLayer(run);
    // Whole device pixels, so the cached layer stays crisp.
    const tx = Math.round(this.ox * dpr);
    const ty = Math.round(this.oy * dpr);
    ctx.drawImage(this.layer, tx, ty);
    ctx.setTransform(this.px, 0, 0, this.px, tx, ty);

    const clock = run.ticks;
    this.drawTunnels(run, g);
    this.drawVeg(g, clock);
    for (const m of g.monsters) this.drawBody(g, m, clock);
    this.drawPlayer(run, g, clock);
    for (const k of g.rocks) this.drawRockNow(k);
    for (const m of g.monsters) {
      if (m.mode === "tunnel" && m.fire?.phase === "breath") {
        drawFlame(ctx, m.x + 0.5, m.y + 0.5, m.fire.dir, flameReach(m), clock, this.px);
      }
    }
    this.drawHarpoon(run, g, clock);
    for (const m of g.monsters) {
      if (m.mode === "ghost" || (m.mode === "flee" && m.y > 0)) {
        drawEyes(ctx, m.x + 0.5, m.y + 0.5, m.kind, m.side, clock, this.px);
      }
    }
    this.drawBursts(run);
    this.drawHurry(g, now);
    this.drawText(run);
  }

  /* ------------------------------------------------------------ layer */

  /** The sky, the dirt and the round's flowers, drawn once per round and size. */
  private ensureLayer(run: Run): void {
    const key = `${run.serial}:${this.cssW}x${this.cssH}@${this.dpr}`;
    if (key === this.layerKey) return;
    this.layerKey = key;
    this.tunnels = null;
    const s = this.px;
    this.layer.width = Math.max(1, Math.round(COLS * s));
    this.layer.height = Math.max(1, Math.round(ROWS * s));
    const ctx = this.layer.getContext("2d");
    if (!ctx) return;
    ctx.setTransform(s, 0, 0, s, 0, 0);

    const sky = ctx.createLinearGradient(0, 0, 0, 1);
    sky.addColorStop(0, C.skyTop);
    sky.addColorStop(1, C.skyLow);
    ctx.fillStyle = sky;
    ctx.fillRect(0, 0, COLS, 1);
    ctx.fillStyle = C.star;
    for (let i = 0; i < 28; i++) {
      ctx.beginPath();
      ctx.arc(noise(i * 3.1) * COLS, 0.06 + noise(i * 7.7) * 0.6, 0.012 + noise(i * 1.3) * 0.022, 0, Math.PI * 2);
      ctx.fill();
    }

    for (let l = 0; l < LAYERS; l++) {
      const y0 = 1 + l * LAYER_ROWS;
      const fill = ctx.createLinearGradient(0, y0, 0, y0 + LAYER_ROWS);
      fill.addColorStop(0, DIRT[l].top);
      fill.addColorStop(1, DIRT[l].bottom);
      ctx.fillStyle = fill;
      ctx.fillRect(0, y0, COLS, LAYER_ROWS);
      if (l > 0) {
        ctx.fillStyle = "rgba(255, 255, 255, 0.07)";
        ctx.fillRect(0, y0 - 0.015, COLS, 0.03);
      }
    }
    for (let r = 1; r < ROWS; r++) {
      ctx.fillStyle = DIRT[layerOf(r)].speck;
      for (let c = 0; c < COLS; c++) {
        for (let i = 0; i < 4; i++) {
          const n = cellOf(c, r) * 4 + i;
          ctx.beginPath();
          ctx.arc(c + noise(n * 1.7 + 0.3), r + noise(n * 2.9 + 0.7), 0.018 + noise(n * 5.1) * 0.03, 0, Math.PI * 2);
          ctx.fill();
        }
      }
    }

    // The ground line, glowing, with tufts of grass.
    ctx.shadowColor = C.grass;
    ctx.shadowBlur = s * 0.25;
    ctx.fillStyle = C.grass;
    ctx.fillRect(0, 0.97, COLS, 0.05);
    ctx.shadowBlur = 0;
    ctx.strokeStyle = C.grass;
    ctx.lineWidth = 0.03;
    for (let i = 0; i < 22; i++) {
      const x = noise(i * 4.7 + 1) * COLS;
      ctx.beginPath();
      ctx.moveTo(x - 0.05, 0.98);
      ctx.lineTo(x - 0.02, 0.88);
      ctx.moveTo(x + 0.03, 0.98);
      ctx.lineTo(x + 0.06, 0.9);
      ctx.stroke();
    }

    // One flower for each round, one big flower for each ten, at the right of the surface.
    const big = Math.min(9, Math.floor(run.round / 10));
    const small = run.round % 10;
    let x = COLS - 0.35;
    for (let i = 0; i < big; i++, x -= 0.5) drawFlower(ctx, x, 0.98, true);
    for (let i = 0; i < small; i++, x -= 0.36) drawFlower(ctx, x, 0.98, false);
  }

  /* ---------------------------------------------------------- tunnels */

  private drawTunnels(run: Run, g: Game): void {
    const key = `${run.serial}:${g.terrain}`;
    if (!this.tunnels || this.tunnels.key !== key) this.tunnels = buildTunnels(g, key);
    const { ctx } = this;
    // Rims stop at the ground line; the open space breaks through it into the sky.
    ctx.save();
    ctx.beginPath();
    ctx.rect(0, 1, COLS, ROWS - 1);
    ctx.clip();
    this.tunnels.rims.forEach((rim, l) => {
      ctx.fillStyle = DIRT[l].rim;
      ctx.fill(rim);
    });
    ctx.restore();
    ctx.save();
    ctx.beginPath();
    ctx.rect(0, 0.96, COLS, ROWS - 0.96);
    ctx.clip();
    ctx.fillStyle = C.tunnel;
    ctx.fill(this.tunnels.holes);
    ctx.restore();
  }

  /* ----------------------------------------------------------- things */

  private drawVeg(g: Game, clock: number): void {
    const v = g.veg;
    if (!v) return;
    // It blinks in its last two seconds.
    if (v.t < 2 * TICK_HZ && Math.floor(clock / 6) % 2 === 0) return;
    const x = colOf(v.cell) + 0.5;
    const y = rowOf(v.cell) + 0.5;
    const pulse = this.reducedMotion ? 0 : Math.sin(clock * 0.12) * 0.05;
    const glow = this.ctx.createRadialGradient(x, y, 0.05, x, y, 0.55 + pulse);
    glow.addColorStop(0, "rgba(253, 230, 138, 0.55)");
    glow.addColorStop(1, "rgba(253, 230, 138, 0)");
    this.ctx.fillStyle = glow;
    this.ctx.fillRect(x - 0.6, y - 0.6, 1.2, 1.2);
    this.emoji(VEGGIES[v.index].emoji, x, y + 0.03, 0.72);
  }

  /** A monster with a body: walking, blown up, bursting, or flattened under a rock. Ghosts come later, on top. */
  private drawBody(g: Game, m: Monster, clock: number): void {
    if (m.mode === "dead" || m.mode === "escaped" || m.mode === "ghost" || (m.mode === "flee" && m.y > 0)) return;
    const { ctx } = this;
    const x = m.x + 0.5;
    const y = m.y + 0.5;
    const draw = m.kind === "pooka" ? drawPooka : drawFygar;
    if (m.mode === "crushed") {
      ctx.save();
      ctx.translate(x, y + 0.25);
      ctx.scale(1.25, 0.35);
      draw(ctx, 0, -0.25, { side: m.side, steps: 0, inflate: 0, t: clock }, this.px);
      ctx.restore();
      return;
    }
    if (m.mode === "popping") {
      // Stretched to bursting, flickering white.
      const f = m.popT / POP_TICKS;
      ctx.save();
      ctx.globalAlpha = 1 - f * 0.6;
      draw(ctx, x, y, { side: m.side, steps: 0, inflate: INFLATE_MAX + f, t: clock }, this.px);
      ctx.restore();
      return;
    }
    draw(ctx, x, y, { side: m.side, steps: m.steps, inflate: m.inflate, t: clock, hot: m.fire?.phase === "charge" }, this.px);
  }

  private drawPlayer(run: Run, g: Game, clock: number): void {
    const a = g.player;
    const p = position(a);
    const { ctx } = this;
    const pose = {
      facing: a.facing,
      side: a.side,
      steps: a.steps,
      moving: a.move !== null && g.harpoon === null && run.phase === "play",
      pumping: g.harpoon?.phase === "hooked" && run.pumpHeld,
      t: clock,
    };
    if (g.status !== "dying" && g.status !== "dead") {
      drawDigger(ctx, p.x + 0.5, p.y + 0.5, pose, this.px);
      return;
    }
    const f = Math.min(1, g.deathT / DEATH_TICKS);
    if (g.status === "dead" || f >= 1) return;
    const rock = g.rocks.find((k) => k.player);
    ctx.save();
    if (g.deathCause === "rock" && rock) {
      // Flattened under the rock that caught him.
      const x = rock.c + 0.5;
      const y = rock.y + 0.5 + 0.38;
      ctx.globalAlpha = 1 - Math.max(0, f - 0.7) / 0.3;
      ctx.translate(x, y);
      ctx.scale(1.3, 0.3);
      drawDigger(ctx, 0, 0, { ...pose, facing: "right", moving: false, pumping: false }, this.px);
    } else {
      // A spin, then a shrink to nothing.
      const x = p.x + 0.5;
      const y = p.y + 0.5;
      const spin = this.reducedMotion ? 0 : Math.min(1, f / 0.6) * Math.PI * 4;
      const size = 1 - Math.max(0, (f - 0.4) / 0.6);
      ctx.translate(x, y);
      ctx.rotate(spin);
      ctx.scale(size, size);
      drawDigger(ctx, 0, 0, { ...pose, moving: false, pumping: false }, this.px);
    }
    ctx.restore();
  }

  private drawRockNow(k: Rock): void {
    const x = k.c + 0.5;
    const y = k.y + 0.5;
    if (k.phase === "crumble") {
      drawRubble(this.ctx, x, y, k.id, Math.min(1, k.t / ROCK_CRUMBLE_TICKS));
      return;
    }
    const shake = k.phase === "loose" && !this.reducedMotion ? Math.sin(k.t * 0.9) : 0;
    drawRock(this.ctx, x + shake * 0.04, y, k.id, shake * 0.12, this.px);
  }

  /** The harpoon: a line out to its barb, or a hose that pulses with each pump once it has hold. */
  private drawHarpoon(run: Run, g: Game, clock: number): void {
    const h = g.harpoon;
    if (!h) return;
    const [dx, dy] = DELTA[h.dir];
    const from = 0.36;
    if (h.len <= from) return;
    const { ctx } = this;
    const x0 = h.x + 0.5 + dx * from;
    const y0 = h.y + 0.5 + dy * from;
    const x1 = h.x + 0.5 + dx * h.len;
    const y1 = h.y + 0.5 + dy * h.len;
    ctx.save();
    ctx.strokeStyle = C.harpoon;
    ctx.lineWidth = 0.05;
    ctx.lineCap = "round";
    ctx.shadowColor = C.harpoonGlow;
    ctx.shadowBlur = this.px * 0.25;
    ctx.beginPath();
    if (h.phase === "hooked") {
      // The hose, rippling; harder while the pump works.
      const amp = run.pumpHeld ? 0.06 : 0.03;
      const n = 14;
      for (let i = 0; i <= n; i++) {
        const t = i / n;
        const wave = Math.sin(t * Math.PI * 3 + clock * 0.5) * amp * Math.sin(t * Math.PI);
        const x = x0 + (x1 - x0) * t - dy * wave;
        const y = y0 + (y1 - y0) * t + dx * wave;
        if (i === 0) ctx.moveTo(x, y);
        else ctx.lineTo(x, y);
      }
    } else {
      ctx.moveTo(x0, y0);
      ctx.lineTo(x1, y1);
    }
    ctx.stroke();
    // The barb.
    ctx.fillStyle = C.harpoon;
    ctx.beginPath();
    ctx.moveTo(x1 + dx * 0.1, y1 + dy * 0.1);
    ctx.lineTo(x1 - dx * 0.06 - dy * 0.09, y1 - dy * 0.06 + dx * 0.09);
    ctx.lineTo(x1 - dx * 0.06 + dy * 0.09, y1 - dy * 0.06 - dx * 0.09);
    ctx.closePath();
    ctx.fill();
    ctx.restore();
  }

  /* ---------------------------------------------------------- effects */

  private drawBursts(run: Run): void {
    const { ctx } = this;
    for (const e of run.effects) {
      if (e.kind === "points") continue;
      const age = run.ticks - e.t0;
      if (age > BURST_TICKS) continue;
      const f = age / BURST_TICKS;
      const [strong, soft] = TINT[e.tint];
      const x = e.x + 0.5;
      const y = e.y + 0.5;
      ctx.save();
      ctx.globalAlpha = 1 - f;
      ctx.strokeStyle = strong;
      ctx.lineWidth = 0.06 * (1 - f) + 0.01;
      ctx.shadowColor = strong;
      ctx.shadowBlur = this.px * 0.35;
      ctx.beginPath();
      ctx.arc(x, y, 0.25 + f * 0.75, 0, Math.PI * 2);
      ctx.stroke();
      ctx.shadowBlur = 0;
      ctx.fillStyle = soft;
      const sparks = e.kind === "bonus" ? 12 : 9;
      for (let i = 0; i < sparks; i++) {
        const a = (i / sparks) * Math.PI * 2 + noise(e.t0 + i) * 0.5;
        const d = 0.2 + f * (0.7 + noise(i * 3.3 + e.t0) * 0.4);
        ctx.beginPath();
        ctx.arc(x + Math.cos(a) * d, y + Math.sin(a) * d, 0.06 * (1 - f) + 0.015, 0, Math.PI * 2);
        ctx.fill();
      }
      ctx.restore();
    }
  }

  /** A red pulse around the field while the monsters hurry. */
  private drawHurry(g: Game, now: number): void {
    if (!g.hurry || g.status !== "play") return;
    const a = this.reducedMotion ? 0.45 : 0.35 + 0.25 * Math.sin(now / 160);
    const { ctx } = this;
    ctx.save();
    ctx.strokeStyle = `rgba(${C.hurry}, ${a})`;
    ctx.lineWidth = 0.08;
    ctx.shadowColor = `rgb(${C.hurry})`;
    ctx.shadowBlur = this.px * 0.4;
    ctx.strokeRect(0.04, 0.04, COLS - 0.08, ROWS - 0.08);
    ctx.restore();
  }

  /** Text goes on in CSS pixels, so the font is never scaled by the cell transform. */
  private drawText(run: Run): void {
    const { ctx, dpr, tile } = this;
    ctx.save();
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.font = `${Math.max(10, Math.round(tile * 0.42))}px "Share Tech Mono", ui-monospace, monospace`;
    for (const e of run.effects) {
      if (e.points <= 0) continue;
      const age = run.ticks - e.t0;
      if (age > POINTS_TICKS) continue;
      const f = age / POINTS_TICKS;
      ctx.globalAlpha = 1 - f * f;
      ctx.fillStyle = C.points;
      ctx.shadowColor = "rgba(251, 191, 36, 0.8)";
      ctx.shadowBlur = 8;
      ctx.fillText(
        e.points.toLocaleString("en-US"),
        this.ox + (e.x + 0.5) * tile,
        this.oy + (e.y + 0.5 - 0.15 - f * 0.8) * tile
      );
    }
    ctx.restore();
  }

  private emoji(ch: string, x: number, y: number, size: number): void {
    const { ctx, dpr, tile } = this;
    ctx.save();
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.font = `${Math.max(10, Math.round(tile * size))}px "Apple Color Emoji", "Segoe UI Emoji", "Noto Color Emoji", sans-serif`;
    ctx.fillText(ch, this.ox + x * tile, this.oy + y * tile);
    ctx.restore();
  }
}

/** The tunnels as paths in cell units: a rim per layer of dirt, and the open space inside. */
function buildTunnels(g: Game, key: string): Tunnels {
  const f = g.field;
  const rims = Array.from({ length: LAYERS }, () => new Path2D());
  const holes = new Path2D();
  const disk = (path: Path2D, x: number, y: number, r: number) => {
    path.moveTo(x + r, y);
    path.arc(x, y, r, 0, Math.PI * 2);
  };
  /** A straight run of tunnel from (x, y) `len` cells along (dx, dy), in the rim colour of layer `l`. */
  const run = (x: number, y: number, dx: number, dy: number, len: number, l: number, end: boolean) => {
    const x1 = x + dx * len;
    const y1 = y + dy * len;
    for (const [path, w] of [
      [rims[l], RIM],
      [holes, HOLE],
    ] as const) {
      if (dx !== 0) path.rect(Math.min(x, x1), y - w, Math.abs(x1 - x), 2 * w);
      else path.rect(x - w, Math.min(y, y1), 2 * w, Math.abs(y1 - y));
      if (end) disk(path, x1, y1, w);
    }
  };
  for (let r = 0; r < ROWS; r++) {
    for (let c = 0; c < COLS; c++) {
      const cell = cellOf(c, r);
      if (!f.dug[cell]) continue;
      const x = c + 0.5;
      const y = r + 0.5;
      const l = layerOf(r);
      if (r > 0) {
        disk(rims[l], x, y, RIM);
        disk(holes, x, y, HOLE);
      }
      if (r > 0 && c + 1 < COLS && f.right[cell]) run(x, y, 1, 0, 1, l, false);
      if (r + 1 < ROWS && f.down[cell]) {
        run(x, y, 0, 1, 0.5, l, false);
        run(x, y + 0.5, 0, 1, 0.5, layerOf(r + 1), false);
      }
    }
  }
  // Ways cut only part of the way: a stub in from each end.
  for (const [id, part] of f.parts) {
    const cell = id >> 1;
    const downward = (id & 1) === 1;
    const c = colOf(cell);
    const r = rowOf(cell);
    const dc = downward ? 0 : 1;
    const dr = downward ? 1 : 0;
    if (part.lo > 0) run(c + 0.5, r + 0.5, dc, dr, part.lo / SUB, layerOf(r), true);
    if (part.hi > 0) run(c + dc + 0.5, r + dr + 0.5, -dc, -dr, part.hi / SUB, layerOf(r + dr), true);
  }
  return { key, rims, holes };
}

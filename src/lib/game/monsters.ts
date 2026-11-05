import { advance, DELTA, DIRS, dirOf, nearestTunnel, OPPOSITE, position, rockAt } from "./board";
import {
  DEFLATE_TICKS,
  FIRE_BREATH_TICKS,
  FIRE_CHARGE_TICKS,
  FIRE_GROW_TICKS,
  FIRE_REACH,
  FIRE_WHIM,
  FLEE_PACE,
  GHOST_MAX_TICKS,
  GHOST_MIN_TICKS,
  HURRY_PACE,
  PACE,
  POP_TICKS,
  ROUND_WALK,
  SUB,
  TICK_HZ,
} from "./constants";
import type { Game } from "./engine";
import { cellOf, colOf, inField, isOpen, rowOf } from "./field";
import type { Dir, Monster, MonsterKind, Move } from "./types";

/*
 * The monsters' minds. In the tunnels a monster with a way to the player
 * takes the shortest one, with the odd wrong turn; one without wanders on
 * along its tunnel. Left there long enough it drifts off as a pair of eyes,
 * straight through the dirt at the player, and comes down into the first
 * tunnel it crosses. A Fygar now and then stops, glows and breathes fire
 * sideways — through dirt too. The last monster left runs for the surface
 * and off the left edge.
 */

export function newMonster(id: number, kind: MonsterKind, home: number): Monster {
  const c = colOf(home);
  const r = rowOf(home);
  return {
    id,
    kind,
    home,
    c,
    r,
    move: null,
    acc: 0,
    steps: 0,
    mode: "tunnel",
    x: c,
    y: r,
    side: 1,
    heading: null,
    inflate: 0,
    deflateT: 0,
    popT: 0,
    points: 0,
    ghostT: 0,
    ghostAt: 0,
    ghostFor: 0,
    landing: -1,
    fire: null,
    fireT: 0,
    fleeT: 0,
  };
}

/** Later rounds wait less: ghost trips and fires come sooner, down to a little over half the wait. */
const roundScale = (g: Game): number => Math.max(0.55, 1 - 0.045 * (g.round - 1));

/** Cells per tick at a speed in sub-steps per second. */
const perTick = (speed: number): number => speed / (SUB * TICK_HZ);

/** Walking speed along the tunnels, in sub-steps per second. */
export function walkSpeed(g: Game): number {
  const base = PACE[g.difficulty].walk + Math.min(g.round - 1, 10) * ROUND_WALK;
  return g.hurry ? base * HURRY_PACE : base;
}

function ghostDelay(g: Game): number {
  const [lo, hi] = PACE[g.difficulty].ghostAfter;
  return Math.round(g.rng.int(lo, hi) * roundScale(g) * (g.hurry ? 0.5 : 1));
}

function fireDelay(g: Game): number {
  const [lo, hi] = PACE[g.difficulty].fireEvery;
  return Math.round(g.rng.int(lo, hi) * roundScale(g));
}

/** Back to its starting cell, normal-sized and calm, as at the start of the round. */
export function resetMonster(g: Game, m: Monster): void {
  m.c = colOf(m.home);
  m.r = rowOf(m.home);
  m.move = null;
  m.acc = 0;
  m.mode = "tunnel";
  m.x = m.c;
  m.y = m.r;
  m.heading = null;
  m.inflate = 0;
  m.deflateT = 0;
  m.popT = 0;
  m.fire = null;
  m.fleeT = 0;
  m.ghostT = 0;
  m.ghostAt = ghostDelay(g);
  m.ghostFor = 0;
  m.landing = -1;
  m.fireT = fireDelay(g);
}

/** Whether the harpoon can catch it: solid, in a tunnel or out on the surface. */
export function hookable(m: Monster): boolean {
  return m.mode === "tunnel" || (m.mode === "flee" && m.y <= 0);
}

export function updateMonster(g: Game, m: Monster): void {
  if (m.mode === "popping") {
    if (++m.popT >= POP_TICKS) {
      m.mode = "dead";
      g.score += m.points;
      g.popped++;
      g.events.push({ kind: "pop", id: m.id, x: m.x, y: m.y, points: m.points });
    }
    return;
  }
  if (m.mode !== "tunnel" && m.mode !== "ghost" && m.mode !== "flee") return;
  if (m.inflate > 0) {
    // Blown up it can't move; once nobody is pumping it shrinks back a size at a time.
    const held = g.harpoon?.phase === "hooked" && g.harpoon.target === m.id;
    if (!held && --m.deflateT <= 0) {
      m.inflate--;
      m.deflateT = DEFLATE_TICKS;
    }
    return;
  }
  if (m.fire) breathe(g, m);
  else if (m.mode === "tunnel") walk(g, m);
  else if (m.mode === "ghost") drift(g, m);
  else flee(g, m);
}

/* ------------------------------------------------------------ tunnels */

function walk(g: Game, m: Monster): void {
  m.ghostT++;
  if (m.fireT > 0) m.fireT--;
  advance(
    m,
    () => walkSpeed(g),
    () => decide(g, m),
    () => {},
    (mv) => {
      m.heading = dirOf(mv.dc, mv.dr);
    }
  );
  const p = position(m);
  m.x = p.x;
  m.y = p.y;
}

/** At a cell's centre: drift off, breathe fire, or pick the next way. */
function decide(g: Game, m: Monster): Move | null {
  if (wantsGhost(g, m)) {
    m.mode = "ghost";
    m.ghostFor = 0;
    m.landing = -1;
    g.events.push({ kind: "ghost", id: m.id });
    return null;
  }
  if (wantsFire(g, m)) {
    m.fire = { phase: "charge", t: 0, dir: m.side };
    g.events.push({ kind: "charge", id: m.id });
    return null;
  }
  const d = chooseWay(g, m);
  if (!d) return null;
  if (d === "left") m.side = -1;
  else if (d === "right") m.side = 1;
  const [dc, dr] = DELTA[d];
  return { dc, dr, p: 0 };
}

/** The shortest way to the player when there is one (now and then a wrong turn), else on along the tunnel. */
function chooseWay(g: Game, m: Monster): Dir | null {
  const ways: Dir[] = [];
  for (const d of DIRS) {
    const [dc, dr] = DELTA[d];
    if (m.r + dr >= 1 && isOpen(g.field, m.c, m.r, dc, dr) && !rockAt(g, m.c + dc, m.r + dr)) ways.push(d);
  }
  if (ways.length === 0) return null;
  const here = g.dist[cellOf(m.c, m.r)];
  if (here > 0 && g.rng.next() >= PACE[g.difficulty].stray) {
    let best: Dir | null = null;
    let fewest = here;
    for (const d of ways) {
      const [dc, dr] = DELTA[d];
      const steps = g.dist[cellOf(m.c + dc, m.r + dr)];
      if (steps >= 0 && steps < fewest) {
        best = d;
        fewest = steps;
      }
    }
    if (best) return best;
  }
  const back = m.heading ? OPPOSITE[m.heading] : null;
  const onward = ways.filter((d) => d !== back);
  if (onward.length === 0) return ways[0];
  if (m.heading && onward.includes(m.heading) && g.rng.next() < 0.7) return m.heading;
  return g.rng.pick(onward);
}

/** Time's up in the tunnels and there's room for another ghost; one already on the player's trail stays on it a while longer. */
function wantsGhost(g: Game, m: Monster): boolean {
  if (m.ghostT < m.ghostAt) return false;
  let out = 0;
  for (const o of g.monsters) if (o.mode === "ghost") out++;
  if (out >= PACE[g.difficulty].ghosts) return false;
  return g.dist[cellOf(m.c, m.r)] < 0 || m.ghostT >= m.ghostAt * 2;
}

/* --------------------------------------------------------------- fire */

/** A rested Fygar breathes at the player in its row nearby, or now and then at nothing at all. */
function wantsFire(g: Game, m: Monster): boolean {
  if (m.kind !== "fygar" || m.fireT > 0) return false;
  const p = position(g.player);
  if (Math.abs(p.y - m.y) < 0.5 && Math.abs(p.x - m.x) <= FIRE_REACH + 1.5) {
    m.side = p.x >= m.x ? 1 : -1;
    return true;
  }
  return g.rng.next() < FIRE_WHIM;
}

function breathe(g: Game, m: Monster): void {
  const f = m.fire;
  if (!f) return;
  f.t++;
  if (f.phase === "charge") {
    if (f.t >= FIRE_CHARGE_TICKS) {
      f.phase = "breath";
      f.t = 0;
      g.events.push({ kind: "fire", id: m.id });
    }
  } else if (f.t >= FIRE_BREATH_TICKS) {
    m.fire = null;
    m.fireT = fireDelay(g);
  }
}

/** How far the flame reaches past the snout right now, in cells; 0 unless it is breathing. */
export function flameReach(m: Monster): number {
  const f = m.fire;
  if (!f || f.phase !== "breath") return 0;
  return FIRE_REACH * Math.min(1, (f.t + 1) / FIRE_GROW_TICKS);
}

/** Whether the point (x, y) is in a Fygar's flame. */
export function inFlame(m: Monster, x: number, y: number): boolean {
  const len = flameReach(m);
  if (len <= 0 || !m.fire) return false;
  const from = m.x + m.fire.dir * 0.35;
  const to = from + m.fire.dir * len;
  return Math.abs(y - m.y) < 0.5 && x > Math.min(from, to) - 0.3 && x < Math.max(from, to) + 0.3;
}

/* ------------------------------------------------------------- ghosts */

/** Eyes only, straight at the player through anything; after a while it comes down into the first tunnel under it. */
function drift(g: Game, m: Monster): void {
  m.ghostFor++;
  const speed = perTick(walkSpeed(g) * PACE[g.difficulty].ghost);
  let tx: number;
  let ty: number;
  if (m.landing >= 0) {
    tx = colOf(m.landing);
    ty = rowOf(m.landing);
  } else {
    const p = position(g.player);
    tx = p.x;
    ty = p.y;
  }
  const dx = tx - m.x;
  const dy = ty - m.y;
  const d = Math.hypot(dx, dy);
  if (m.landing >= 0 && d <= speed) {
    m.x = tx;
    m.y = ty;
    m.c = tx;
    m.r = ty;
    m.move = null;
    m.acc = 0;
    m.mode = "tunnel";
    m.landing = -1;
    m.heading = null;
    m.ghostT = 0;
    m.ghostAt = ghostDelay(g);
    return;
  }
  if (d > 1e-9) {
    const k = Math.min(speed, d) / d;
    m.x += dx * k;
    m.y += dy * k;
    if (Math.abs(dx) > 0.05) m.side = dx > 0 ? 1 : -1;
  }
  if (m.landing >= 0 || m.ghostFor < GHOST_MIN_TICKS) return;
  const c = Math.round(m.x);
  const r = Math.round(m.y);
  const over = Math.abs(m.x - c) < 0.45 && Math.abs(m.y - r) < 0.45;
  if (over && r >= 1 && inField(c, r) && g.field.dug[cellOf(c, r)] && !rockAt(g, c, r)) m.landing = cellOf(c, r);
  else if (m.ghostFor >= GHOST_MAX_TICKS) m.landing = nearestTunnel(g, m.x, m.y);
}

/* --------------------------------------------------------------- flee */

export function startFlee(g: Game, m: Monster): void {
  m.mode = "flee";
  m.move = null;
  m.acc = 0;
  m.landing = -1;
  m.fire = null;
  g.events.push({ kind: "flee", id: m.id });
}

/** Up through the dirt as eyes, then solid along the surface and out at the left edge. */
function flee(g: Game, m: Monster): void {
  if (m.y > 0) {
    const speed = perTick(walkSpeed(g) * PACE[g.difficulty].ghost);
    const col = Math.round(m.x);
    m.x += Math.max(-speed, Math.min(speed, col - m.x));
    m.y = Math.max(0, m.y - speed);
    return;
  }
  const speed = perTick(walkSpeed(g) * FLEE_PACE);
  m.x -= speed;
  m.side = -1;
  // The walk cycle counts sub-steps, as it does in the tunnels.
  m.acc += speed * SUB;
  while (m.acc >= 1) {
    m.acc--;
    m.steps++;
  }
  if (m.x <= -0.8) {
    m.mode = "escaped";
    g.events.push({ kind: "escape", id: m.id });
  }
}

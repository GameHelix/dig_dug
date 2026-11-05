import { COLS, ROWS, SUB, TICK_HZ } from "./constants";
import type { Game } from "./engine";
import { cellOf, dugFrom, inField, isOpen } from "./field";
import type { Dir, Move, Rock, Walker } from "./types";

/*
 * Helpers shared by the engine and the monsters: moving a walker cell to
 * cell, finding rocks, and reading the tunnels the way the harpoon and the
 * path-finding need them.
 */

export const DELTA: Record<Dir, readonly [-1 | 0 | 1, -1 | 0 | 1]> = {
  left: [-1, 0],
  right: [1, 0],
  up: [0, -1],
  down: [0, 1],
};

export const DIRS: readonly Dir[] = ["up", "left", "down", "right"];

export const OPPOSITE: Record<Dir, Dir> = { left: "right", right: "left", up: "down", down: "up" };

export function dirOf(dc: number, dr: number): Dir {
  if (dc !== 0) return dc < 0 ? "left" : "right";
  return dr < 0 ? "up" : "down";
}

/** A walker's centre, in cells, part-way along its move. */
export function position(w: Walker): { x: number; y: number } {
  const m = w.move;
  return m ? { x: w.c + (m.dc * m.p) / SUB, y: w.r + (m.dr * m.p) / SUB } : { x: w.c, y: w.r };
}

/**
 * Move a walker on by one tick. Speed, in sub-steps per second, is banked in
 * `acc`; each whole sub-step advances the move and calls `onStep`, and a move
 * that reaches the next centre lands there (`arrive`) and asks `decide` for
 * the next one, so a held direction runs on without a pause. With nothing to
 * do the walker stands and the bank empties.
 */
export function advance(
  w: Walker,
  speed: (m: Move) => number,
  decide: () => Move | null,
  onStep: (m: Move) => void,
  arrive: (m: Move) => void
): void {
  let m = w.move ?? decide();
  w.move = m;
  if (!m) {
    w.acc = 0;
    return;
  }
  w.acc += speed(m);
  while (w.acc >= TICK_HZ) {
    w.acc -= TICK_HZ;
    m.p++;
    w.steps++;
    onStep(m);
    if (m.p < SUB) continue;
    w.c += m.dc;
    w.r += m.dr;
    w.move = null;
    arrive(m);
    m = decide();
    w.move = m;
    if (!m) {
      w.acc = 0;
      return;
    }
  }
}

/** The rock in (c, r): one resting or wobbling there, or one falling through. A rock breaking up is in nobody's way. */
export function rockAt(g: Game, c: number, r: number): Rock | null {
  for (const k of g.rocks) {
    if (k.c !== c || k.phase === "crumble") continue;
    if (k.phase === "fall" ? Math.abs(k.y - r) < 1 : k.r === r) return k;
  }
  return null;
}

/** Whether a point is inside a rock that is still whole. */
export function rockNear(g: Game, x: number, y: number): boolean {
  return g.rocks.some((k) => k.phase !== "crumble" && Math.abs(k.c - x) < 0.5 && Math.abs(k.y - y) < 0.5);
}

/** The dug cell the monsters trail the player to: the nearer end of its move, or whichever end is dug. */
export function playerCell(g: Game): number {
  const a = g.player;
  const here = cellOf(a.c, a.r);
  const m = a.move;
  if (!m) return here;
  const there = cellOf(a.c + m.dc, a.r + m.dr);
  const near = m.p * 2 < SUB ? here : there;
  const far = near === here ? there : here;
  if (g.field.dug[near]) return near;
  return g.field.dug[far] ? far : here;
}

/** How far the open space reaches around a dug cell's centre: the whole cell up in the sky. */
const HOLE = 0.42;
const reach = (r: number): number => (r === 0 ? 0.5 : HOLE);

/**
 * Whether a point lies in open tunnel or sky, for the harpoon. It flies along
 * the player's row or column, so the points it asks about sit on those lines;
 * anywhere else counts as dirt.
 */
export function openAt(g: Game, x: number, y: number): boolean {
  if (x < 0 || x > COLS - 1 || y < 0 || y > ROWS - 1) return false;
  const cx = Math.round(x);
  const ry = Math.round(y);
  const onRow = Math.abs(y - ry) < 1e-6;
  const onCol = Math.abs(x - cx) < 1e-6;
  if (onRow && onCol) return g.field.dug[cellOf(cx, ry)] === 1;
  if (onRow) {
    const c = Math.floor(x);
    return openSpan(g, c, ry, 1, 0, x - c);
  }
  if (onCol) {
    const r = Math.floor(y);
    return openSpan(g, cx, r, 0, 1, y - r);
  }
  return false;
}

/** Whether the point `t` of the way from (c, r) to its neighbour along (dc, dr) is open: 0 is (c, r)'s centre. */
function openSpan(g: Game, c: number, r: number, dc: number, dr: number, t: number): boolean {
  const f = g.field;
  if (isOpen(f, c, r, dc, dr)) return true;
  if (f.dug[cellOf(c, r)] && t <= Math.max(reach(r), dugFrom(f, c, r, dc, dr) / SUB)) return true;
  const nc = c + dc;
  const nr = r + dr;
  return (
    inField(nc, nr) &&
    f.dug[cellOf(nc, nr)] === 1 &&
    1 - t <= Math.max(reach(nr), dugFrom(f, nc, nr, -dc, -dr) / SUB)
  );
}

/** The dug cell below the surface nearest to (x, y) with no rock in it. */
export function nearestTunnel(g: Game, x: number, y: number): number {
  let best = -1;
  let bestD = Infinity;
  for (let r = 1; r < ROWS; r++) {
    for (let c = 0; c < COLS; c++) {
      if (!g.field.dug[cellOf(c, r)] || rockAt(g, c, r)) continue;
      const d = (c - x) ** 2 + (r - y) ** 2;
      if (d < bestD) {
        bestD = d;
        best = cellOf(c, r);
      }
    }
  }
  return best;
}

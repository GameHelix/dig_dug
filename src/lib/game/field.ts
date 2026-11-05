import { COLS, LAYER_ROWS, LAYERS, ROWS, SUB } from "./constants";

/*
 * The tunnels: which cells the digging has reached, which ways between
 * neighbours are open, and the ways cut only part of the way. A cell is dug
 * once a tunnel reaches its centre, and two dug neighbours are joined only
 * where the way between them is open, so tunnels side by side keep a skin of
 * dirt between them. The surface row is open air from end to end.
 */

export const cellOf = (c: number, r: number): number => r * COLS + c;
export const colOf = (cell: number): number => cell % COLS;
export const rowOf = (cell: number): number => Math.floor(cell / COLS);
export const inField = (c: number, r: number): boolean => c >= 0 && c < COLS && r >= 0 && r < ROWS;

/** The dirt layer of a row, 0 at the top to 3 at the bottom; the surface counts with the first. */
export const layerOf = (r: number): number => Math.min(LAYERS - 1, Math.max(0, Math.floor((r - 1) / LAYER_ROWS)));

/** A way cut part of the way: sub-steps in from its left or upper end, and from its right or lower end. */
export interface Part {
  lo: number;
  hi: number;
}

export interface Field {
  /** 1 where a tunnel reaches the cell's centre. */
  dug: Uint8Array;
  /** 1 where the way from a cell to its right-hand neighbour is open. */
  right: Uint8Array;
  /** 1 where the way from a cell down to the row below is open. */
  down: Uint8Array;
  /** Ways cut part of the way, by `wayId`. */
  parts: Map<number, Part>;
}

export function createField(): Field {
  const n = COLS * ROWS;
  const f: Field = { dug: new Uint8Array(n), right: new Uint8Array(n), down: new Uint8Array(n), parts: new Map() };
  for (let c = 0; c < COLS; c++) {
    f.dug[cellOf(c, 0)] = 1;
    if (c + 1 < COLS) f.right[cellOf(c, 0)] = 1;
  }
  return f;
}

export function cloneField(f: Field): Field {
  return {
    dug: f.dug.slice(),
    right: f.right.slice(),
    down: f.down.slice(),
    parts: new Map([...f.parts].map(([id, part]) => [id, { ...part }])),
  };
}

/** The way from (c, r) one step along (dc, dr), by its left or upper cell, doubled, plus one if it runs down. */
export function wayId(c: number, r: number, dc: number, dr: number): number {
  return dc !== 0 ? cellOf(Math.min(c, c + dc), r) * 2 : cellOf(c, Math.min(r, r + dr)) * 2 + 1;
}

/** Whether the way from (c, r) one step along (dc, dr) is open all the way. */
export function isOpen(f: Field, c: number, r: number, dc: number, dr: number): boolean {
  const nc = c + dc;
  const nr = r + dr;
  if (!inField(c, r) || !inField(nc, nr) || Math.abs(dc) + Math.abs(dr) !== 1) return false;
  return dc !== 0 ? f.right[cellOf(Math.min(c, nc), r)] === 1 : f.down[cellOf(c, Math.min(r, nr))] === 1;
}

/** How many sub-steps of the way from (c, r) along (dc, dr) are dug from this end: SUB when it is open. */
export function dugFrom(f: Field, c: number, r: number, dc: number, dr: number): number {
  if (isOpen(f, c, r, dc, dr)) return SUB;
  const part = f.parts.get(wayId(c, r, dc, dr));
  if (!part) return 0;
  return dc + dr > 0 ? part.lo : part.hi;
}

/** Open the way between two neighbours outright, and both cells with it. */
export function openWay(f: Field, c: number, r: number, dc: number, dr: number): void {
  const nc = c + dc;
  const nr = r + dr;
  if (dc !== 0) f.right[cellOf(Math.min(c, nc), r)] = 1;
  else f.down[cellOf(c, Math.min(r, nr))] = 1;
  f.dug[cellOf(c, r)] = 1;
  f.dug[cellOf(nc, nr)] = 1;
  f.parts.delete(wayId(c, r, dc, dr));
}

/**
 * Cut the way from (c, r) along (dc, dr) to `depth` sub-steps in from this
 * end. The way opens once the cuts from its two ends meet. Returns whether
 * anything changed.
 */
export function cut(f: Field, c: number, r: number, dc: number, dr: number, depth: number): boolean {
  if (isOpen(f, c, r, dc, dr)) return false;
  const id = wayId(c, r, dc, dr);
  const part = f.parts.get(id) ?? { lo: 0, hi: 0 };
  const fromLo = dc + dr > 0;
  if (depth <= (fromLo ? part.lo : part.hi)) return false;
  if (fromLo) part.lo = depth;
  else part.hi = depth;
  if (part.lo + part.hi >= SUB) openWay(f, c, r, dc, dr);
  else f.parts.set(id, part);
  return true;
}

const STEPS: readonly (readonly [number, number])[] = [
  [1, 0],
  [-1, 0],
  [0, 1],
  [0, -1],
];

/**
 * Steps along open tunnel from `from` to every cell below the surface, -1
 * where there is no way: the trail the monsters follow. `blocked` cells (the
 * rocks) are walls, and nothing goes up onto the surface this way.
 */
export function tunnelSteps(f: Field, from: number, blocked: (cell: number) => boolean): Int16Array {
  const steps = new Int16Array(COLS * ROWS).fill(-1);
  if (from < 0 || rowOf(from) < 1 || blocked(from)) return steps;
  const queue = [from];
  steps[from] = 0;
  for (let i = 0; i < queue.length; i++) {
    const cell = queue[i];
    const c = colOf(cell);
    const r = rowOf(cell);
    for (const [dc, dr] of STEPS) {
      if (r + dr < 1 || !isOpen(f, c, r, dc, dr)) continue;
      const next = cellOf(c + dc, r + dr);
      if (steps[next] >= 0 || blocked(next)) continue;
      steps[next] = steps[cell] + 1;
      queue.push(next);
    }
  }
  return steps;
}

import { COLS, ROWS, START_COL, START_ROW } from "./constants";
import { cellOf, colOf, createField, inField, openWay, rowOf, type Field } from "./field";
import { makeRng, type Rng } from "./rng";
import type { MonsterKind } from "./types";

/*
 * Each round's field, the same every time that round comes up: the shaft from
 * the surface down to the middle, where the player starts, a short sealed
 * tunnel for each monster (or for two), and the rocks waiting in the dirt.
 * The monsters' tunnels never touch the shaft or each other, and no rock
 * starts over open space, so nothing falls until the digging begins.
 */

export interface MonsterStart {
  kind: MonsterKind;
  cell: number;
}

export interface Layout {
  round: number;
  /** The field as the round starts: the surface, the shaft and the monsters' tunnels. */
  field: Field;
  monsters: MonsterStart[];
  rocks: number[];
  /** Each monster tunnel's cells, end to end. */
  tunnels: number[][];
}

export interface Plan {
  monsters: number;
  fygars: number;
  rocks: number;
  tunnels: number;
}

/** What a round brings: a monster more every other round up to eight, a growing share of them Fygars, more rocks. */
export function plan(round: number): Plan {
  const monsters = Math.min(4 + Math.floor((round - 1) / 2), 8);
  const fygars = Math.max(1, Math.round(monsters * Math.min(0.5, 0.22 + 0.03 * round)));
  const rocks = Math.min(3 + Math.floor((round - 1) / 3), 6);
  return { monsters, fygars, rocks, tunnels: Math.min(monsters, 6) };
}

/** Kept clear of the monsters: the shaft with a cell of dirt either side, and everywhere within four steps of the start. */
export function nearStart(c: number, r: number): boolean {
  return (Math.abs(c - START_COL) <= 1 && r <= START_ROW + 1) || Math.abs(c - START_COL) + Math.abs(r - START_ROW) <= 4;
}

export function makeLayout(round: number): Layout {
  const rng = makeRng(`dig_dug:round:${round}`);
  const p = plan(round);
  const field = createField();
  for (let r = 0; r < START_ROW; r++) openWay(field, START_COL, r, 0, 1);

  // The first tunnels hold two monsters, one at each end of four cells; the rest hold one in the middle of three.
  const pairs = p.monsters - p.tunnels;
  const taken = new Uint8Array(COLS * ROWS);
  const tunnels: number[][] = [];
  const homes: number[] = [];
  for (let t = 0; t < p.tunnels; t++) {
    const len = t < pairs ? 4 : 3;
    const cells = placeTunnel(rng, taken, len);
    for (let i = 0; i + 1 < len; i++) {
      const a = cells[i];
      const b = cells[i + 1];
      openWay(field, colOf(a), rowOf(a), colOf(b) - colOf(a), rowOf(b) - rowOf(a));
    }
    tunnels.push(cells);
    if (len === 4) homes.push(cells[0], cells[3]);
    else homes.push(cells[1]);
  }

  const kinds: MonsterKind[] = Array.from({ length: p.monsters }, (_, i) => (i < p.fygars ? "fygar" : "pooka"));
  rng.shuffle(kinds);

  return {
    round,
    field,
    monsters: homes.map((cell, i) => ({ kind: kinds[i], cell })),
    rocks: placeRocks(rng, field, p.rocks),
    tunnels,
  };
}

/** A straight run of `len` cells, across or down, clear of the start and a cell away from every other tunnel. */
function placeTunnel(rng: Rng, taken: Uint8Array, len: number): number[] {
  for (let attempt = 0; attempt < 1000; attempt++) {
    const across = rng.next() < 0.5;
    const c0 = rng.int(0, across ? COLS - len : COLS - 1);
    const r0 = rng.int(2, across ? ROWS - 1 : ROWS - len);
    const cells: number[] = [];
    for (let i = 0; i < len; i++) {
      const c = across ? c0 + i : c0;
      const r = across ? r0 : r0 + i;
      if (nearStart(c, r) || taken[cellOf(c, r)]) break;
      cells.push(cellOf(c, r));
    }
    if (cells.length < len) continue;
    for (const cell of cells) {
      for (let dr = -1; dr <= 1; dr++) {
        for (let dc = -1; dc <= 1; dc++) {
          const c = colOf(cell) + dc;
          const r = rowOf(cell) + dr;
          if (inField(c, r)) taken[cellOf(c, r)] = 1;
        }
      }
    }
    return cells;
  }
  throw new Error("No room left for a monster tunnel");
}

/**
 * Rocks sit in solid dirt with solid dirt under them, never in the top row of
 * dirt or the bottom one, never touching another rock or sharing a column
 * with one close above or below, and never right next to the start.
 */
function placeRocks(rng: Rng, field: Field, count: number): number[] {
  const rocks: number[] = [];
  const fits = (c: number, r: number): boolean => {
    if (field.dug[cellOf(c, r)] || field.dug[cellOf(c, r + 1)]) return false;
    if (Math.abs(c - START_COL) + Math.abs(r - START_ROW) <= 1) return false;
    return rocks.every((k) => {
      const dc = Math.abs(colOf(k) - c);
      const dr = Math.abs(rowOf(k) - r);
      return (dc > 1 || dr > 1) && (dc > 0 || dr > 3);
    });
  };
  for (let i = 0; i < count; i++) {
    const options: number[] = [];
    for (let r = 2; r <= ROWS - 2; r++) {
      for (let c = 0; c < COLS; c++) if (fits(c, r)) options.push(cellOf(c, r));
    }
    if (options.length === 0) break;
    rocks.push(rng.pick(options));
  }
  return rocks;
}

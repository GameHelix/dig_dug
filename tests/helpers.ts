import { COLS, ROWS } from "@/lib/game/constants";
import { createGame, step, type Game } from "@/lib/game/engine";
import { cellOf, createField, openWay } from "@/lib/game/field";
import { newMonster, resetMonster } from "@/lib/game/monsters";
import type { Difficulty, Dir, Monster, MonsterKind, Rock } from "@/lib/game/types";

/** Never, as far as a test is concerned. */
export const NEVER = 1_000_000;

/**
 * A round-1 game emptied for a test: only the surface and the shaft are open,
 * and two monsters are shut in pockets in the bottom corners, never ghosting —
 * two, so neither is ever the last one left and runs, and the round can't end
 * on its own. Tests add what they need.
 */
export function bare(difficulty: Difficulty = "classic"): Game {
  const g = createGame(1, difficulty, "test");
  const f = createField();
  for (let r = 0; r < 6; r++) openWay(f, 7, r, 0, 1);
  g.field = f;
  g.rocks = [];
  g.monsters = [];
  addMonster(g, "pooka", 0, ROWS - 1);
  addMonster(g, "pooka", COLS - 1, ROWS - 1);
  return g;
}

/** Open a tunnel through the cells given as [c, r] pairs, each a neighbour of the one before. */
export function tunnel(g: Game, ...cells: [number, number][]): void {
  for (let i = 0; i + 1 < cells.length; i++) {
    const [c, r] = cells[i];
    const [nc, nr] = cells[i + 1];
    openWay(g.field, c, r, nc - c, nr - r);
  }
  if (cells.length === 1) g.field.dug[cellOf(cells[0][0], cells[0][1])] = 1;
}

/** A straight tunnel along row `r` from column `from` to `to`. */
export function across(g: Game, r: number, from: number, to: number): void {
  const cells: [number, number][] = [];
  for (let c = Math.min(from, to); c <= Math.max(from, to); c++) cells.push([c, r]);
  tunnel(g, ...cells);
}

/** A straight tunnel down column `c` from row `from` to `to`. */
export function down(g: Game, c: number, from: number, to: number): void {
  const cells: [number, number][] = [];
  for (let r = Math.min(from, to); r <= Math.max(from, to); r++) cells.push([c, r]);
  tunnel(g, ...cells);
}

/** A monster standing on (c, r), its cell dug; it waits NEVER ticks to ghost unless told otherwise. */
export function addMonster(g: Game, kind: MonsterKind, c: number, r: number): Monster {
  const m = newMonster(g.monsters.length, kind, cellOf(c, r));
  g.field.dug[cellOf(c, r)] = 1;
  g.monsters.push(m);
  resetMonster(g, m);
  m.ghostAt = NEVER;
  return m;
}

export function addRock(g: Game, c: number, r: number): Rock {
  const k: Rock = { id: g.rocks.length, c, r, y: r, phase: "set", t: 0, crushed: [], player: false };
  g.rocks.push(k);
  return k;
}

/** Put the player on (c, r), standing still. */
export function place(g: Game, c: number, r: number, facing: Dir = "right"): void {
  const a = g.player;
  a.c = c;
  a.r = r;
  a.move = null;
  a.acc = 0;
  a.facing = facing;
}

/** Step `ticks` times holding `dirs`, most recent first. */
export function hold(g: Game, ticks: number, ...dirs: Dir[]): void {
  for (let i = 0; i < ticks; i++) step(g, { dirs, pump: false });
}

/** Step `ticks` times with the pump held. */
export function pumpFor(g: Game, ticks: number): void {
  for (let i = 0; i < ticks; i++) step(g, { dirs: [], pump: true });
}

/** Step holding `dirs` until `done` holds; the ticks it took. Fails after `limit`. */
export function until(g: Game, done: () => boolean, dirs: Dir[] = [], limit = 3000): number {
  for (let t = 0; t < limit; t++) {
    if (done()) return t;
    step(g, { dirs, pump: false });
  }
  throw new Error(`not done after ${limit} ticks`);
}

/** The walker stands still exactly on (c, r). */
export const at = (w: { c: number; r: number; move: unknown }, c: number, r: number): boolean =>
  w.move === null && w.c === c && w.r === r;

export const cell = cellOf;

/** The field as text, for a failing test's message: # dirt, . tunnel, o rock, P player, M monster. */
export function picture(g: Game): string {
  const rows: string[] = [];
  for (let r = 0; r < ROWS; r++) {
    let line = "";
    for (let c = 0; c < COLS; c++) {
      const i = cellOf(c, r);
      let ch = g.field.dug[i] ? "." : "#";
      if (g.rocks.some((k) => k.c === c && Math.round(k.y) === r)) ch = "o";
      if (g.monsters.some((m) => m.mode !== "dead" && m.mode !== "escaped" && Math.round(m.x) === c && Math.round(m.y) === r))
        ch = "M";
      if (g.player.c === c && g.player.r === r) ch = "P";
      line += ch;
    }
    rows.push(line);
  }
  return rows.join("\n");
}

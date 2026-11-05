import { describe, expect, it } from "vitest";
import { ROWS, START_COL, START_ROW } from "@/lib/game/constants";
import { cellOf, colOf, isOpen, rowOf, tunnelSteps } from "@/lib/game/field";
import { makeLayout, nearStart, plan } from "@/lib/game/layout";

const ROUNDS = Array.from({ length: 150 }, (_, i) => i + 1);

describe("what a round brings", () => {
  it("starts with four monsters, one a Fygar, and three rocks", () => {
    expect(plan(1)).toEqual({ monsters: 4, fygars: 1, rocks: 3, tunnels: 4 });
  });

  it("adds monsters, Fygars and rocks as the rounds go by, up to eight monsters, half of them Fygars", () => {
    for (let round = 2; round <= 40; round++) {
      const a = plan(round - 1);
      const b = plan(round);
      expect(b.monsters).toBeGreaterThanOrEqual(a.monsters);
      expect(b.rocks).toBeGreaterThanOrEqual(a.rocks);
    }
    expect(plan(40)).toEqual({ monsters: 8, fygars: 4, rocks: 6, tunnels: 6 });
  });
});

describe("a round's layout", () => {
  it("is the same every time its round comes up, and differs from round to round", () => {
    expect(makeLayout(7)).toEqual(makeLayout(7));
    expect(makeLayout(7).monsters).not.toEqual(makeLayout(8).monsters);
  });

  it("opens the shaft from the surface down to where the player starts", () => {
    const { field } = makeLayout(1);
    for (let r = 0; r < START_ROW; r++) expect(isOpen(field, START_COL, r, 0, 1)).toBe(true);
    expect(isOpen(field, START_COL, START_ROW, 0, 1)).toBe(false);
  });

  it.each(ROUNDS)("round %i: every monster in its own sealed tunnel, away from the start", (round) => {
    const layout = makeLayout(round);
    const p = plan(round);
    expect(layout.monsters).toHaveLength(p.monsters);
    expect(layout.monsters.filter((m) => m.kind === "fygar")).toHaveLength(p.fygars);
    expect(layout.tunnels).toHaveLength(p.tunnels);

    const { field } = layout;
    const fromStart = tunnelSteps(field, cellOf(START_COL, START_ROW), () => false);
    for (const m of layout.monsters) {
      const c = colOf(m.cell);
      const r = rowOf(m.cell);
      expect(field.dug[m.cell]).toBe(1);
      expect(r).toBeGreaterThanOrEqual(2);
      expect(nearStart(c, r)).toBe(false);
      expect(fromStart[m.cell]).toBe(-1);
    }

    // Tunnels keep a cell of dirt between them, so none joins another.
    const owner = new Map<number, number>();
    layout.tunnels.forEach((cells, t) => cells.forEach((cell) => owner.set(cell, t)));
    for (const [cell, t] of owner) {
      for (const [other, u] of owner) {
        if (t === u) continue;
        const near = Math.max(Math.abs(colOf(cell) - colOf(other)), Math.abs(rowOf(cell) - rowOf(other)));
        expect(near).toBeGreaterThanOrEqual(2);
      }
    }
  });

  it.each(ROUNDS)("round %i: rocks sit in solid dirt over solid dirt, apart from each other", (round) => {
    const layout = makeLayout(round);
    expect(layout.rocks).toHaveLength(plan(round).rocks);
    for (const rock of layout.rocks) {
      const c = colOf(rock);
      const r = rowOf(rock);
      expect(r).toBeGreaterThanOrEqual(2);
      expect(r).toBeLessThanOrEqual(ROWS - 2);
      expect(layout.field.dug[rock]).toBe(0);
      expect(layout.field.dug[cellOf(c, r + 1)]).toBe(0);
      for (const other of layout.rocks) {
        if (other === rock) continue;
        const dc = Math.abs(colOf(other) - c);
        const dr = Math.abs(rowOf(other) - r);
        expect(dc > 1 || dr > 1).toBe(true);
      }
    }
  });
});

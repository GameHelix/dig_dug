import { describe, expect, it } from "vitest";
import { COLS, ROWS, SUB } from "@/lib/game/constants";
import {
  cellOf,
  cloneField,
  colOf,
  createField,
  cut,
  dugFrom,
  isOpen,
  layerOf,
  openWay,
  rowOf,
  tunnelSteps,
  wayId,
} from "@/lib/game/field";

describe("the field", () => {
  it("numbers cells row by row", () => {
    expect(cellOf(0, 0)).toBe(0);
    expect(cellOf(COLS - 1, ROWS - 1)).toBe(COLS * ROWS - 1);
    expect(colOf(cellOf(4, 9))).toBe(4);
    expect(rowOf(cellOf(4, 9))).toBe(9);
  });

  it("splits the dirt into four layers of three rows, the surface counting with the first", () => {
    expect([0, 1, 3, 4, 6, 7, 9, 10, 12].map(layerOf)).toEqual([0, 0, 0, 1, 1, 2, 2, 3, 3]);
  });

  it("starts with the surface open from end to end and the dirt whole", () => {
    const f = createField();
    for (let c = 0; c < COLS; c++) expect(f.dug[cellOf(c, 0)]).toBe(1);
    for (let c = 0; c + 1 < COLS; c++) expect(isOpen(f, c, 0, 1, 0)).toBe(true);
    expect(isOpen(f, 3, 0, 0, 1)).toBe(false);
    expect(f.dug.reduce((n, v) => n + v, 0)).toBe(COLS);
  });

  it("gives a way the same id from either end", () => {
    expect(wayId(3, 4, 1, 0)).toBe(wayId(4, 4, -1, 0));
    expect(wayId(3, 4, 0, 1)).toBe(wayId(3, 5, 0, -1));
    expect(wayId(3, 4, 1, 0)).not.toBe(wayId(3, 4, 0, 1));
  });

  it("never opens a way off the field", () => {
    const f = createField();
    expect(isOpen(f, 0, 0, -1, 0)).toBe(false);
    expect(isOpen(f, COLS - 1, 0, 1, 0)).toBe(false);
    expect(isOpen(f, 0, 0, 0, -1)).toBe(false);
  });

  it("cuts a way from one end, deeper only, and opens it when the cut reaches across", () => {
    const f = createField();
    openWay(f, 5, 5, 0, 1);
    expect(cut(f, 5, 5, 1, 0, 4)).toBe(true);
    expect(dugFrom(f, 5, 5, 1, 0)).toBe(4);
    expect(dugFrom(f, 6, 5, -1, 0)).toBe(0);
    expect(cut(f, 5, 5, 1, 0, 3)).toBe(false);
    expect(isOpen(f, 5, 5, 1, 0)).toBe(false);
    expect(f.dug[cellOf(6, 5)]).toBe(0);
    expect(cut(f, 5, 5, 1, 0, SUB)).toBe(true);
    expect(isOpen(f, 6, 5, -1, 0)).toBe(true);
    expect(f.dug[cellOf(6, 5)]).toBe(1);
    expect(f.parts.size).toBe(0);
  });

  it("opens a way where cuts from its two ends meet", () => {
    const f = createField();
    cut(f, 2, 8, 0, 1, 5);
    cut(f, 2, 9, 0, -1, 6);
    expect(isOpen(f, 2, 8, 0, 1)).toBe(false);
    cut(f, 2, 9, 0, -1, 7);
    expect(isOpen(f, 2, 8, 0, 1)).toBe(true);
  });

  it("copies a field without sharing anything", () => {
    const f = createField();
    cut(f, 1, 1, 1, 0, 3);
    const copy = cloneField(f);
    openWay(copy, 4, 4, 1, 0);
    cut(copy, 1, 1, 1, 0, 6);
    expect(f.dug[cellOf(4, 4)]).toBe(0);
    expect(dugFrom(f, 1, 1, 1, 0)).toBe(3);
  });
});

describe("the monsters' trail", () => {
  it("counts steps along open tunnel, around corners", () => {
    const f = createField();
    openWay(f, 2, 3, 1, 0);
    openWay(f, 3, 3, 0, 1);
    openWay(f, 3, 4, 0, 1);
    const steps = tunnelSteps(f, cellOf(2, 3), () => false);
    expect(steps[cellOf(2, 3)]).toBe(0);
    expect(steps[cellOf(3, 5)]).toBe(3);
    expect(steps[cellOf(4, 3)]).toBe(-1);
  });

  it("goes no further than the tunnels: not through dirt, not past a rock, not up onto the surface", () => {
    const f = createField();
    openWay(f, 6, 1, 0, -1);
    openWay(f, 6, 1, 1, 0);
    openWay(f, 7, 1, 1, 0);
    openWay(f, 6, 3, 1, 0);
    const steps = tunnelSteps(f, cellOf(6, 1), (cell) => cell === cellOf(7, 1));
    expect(steps[cellOf(7, 1)]).toBe(-1);
    expect(steps[cellOf(8, 1)]).toBe(-1);
    expect(steps[cellOf(6, 0)]).toBe(-1);
    expect(steps[cellOf(6, 3)]).toBe(-1);
  });

  it("has no trail at all from the surface", () => {
    const steps = tunnelSteps(createField(), cellOf(4, 0), () => false);
    expect(steps.every((s) => s === -1)).toBe(true);
  });
});

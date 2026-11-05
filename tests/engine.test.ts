import { describe, expect, it } from "vitest";
import { position } from "@/lib/game/board";
import { DIG_POINTS, INFLATE_MAX, POP_POINTS, PUMP_RANGE, START_COL, START_ROW } from "@/lib/game/constants";
import { createGame, requestPump, step } from "@/lib/game/engine";
import { cellOf, dugFrom, isOpen, layerOf } from "@/lib/game/field";
import { across, addMonster, addRock, at, bare, down, hold, place, pumpFor, until } from "./helpers";

describe("the player", () => {
  it("starts each round at the foot of the shaft, facing right", () => {
    const g = createGame(1, "classic", 1);
    expect(at(g.player, START_COL, START_ROW)).toBe(true);
    expect(g.player.facing).toBe("right");
    expect(isOpen(g.field, START_COL, 0, 0, 1)).toBe(true);
  });

  it("moves one whole cell for a tap, then stands", () => {
    const g = bare();
    hold(g, 1, "up");
    expect(until(g, () => at(g.player, 7, 5))).toBeLessThan(20);
    hold(g, 30);
    expect(at(g.player, 7, 5)).toBe(true);
  });

  it("runs a tunnel at a little over four cells a second and digs at a little over three", () => {
    const g = bare();
    const run = until(g, () => g.player.r <= 1, ["up"]);
    expect(run).toBeGreaterThanOrEqual(70);
    expect(run).toBeLessThanOrEqual(74);
    place(g, 7, 6);
    const dig = until(g, () => g.player.c >= 12, ["right"]);
    expect(dig).toBeGreaterThanOrEqual(93);
    expect(dig).toBeLessThanOrEqual(97);
  });

  it("scores for every new cell of dirt and nothing along a tunnel", () => {
    const g = bare();
    until(g, () => g.player.c === 9, ["right"]);
    until(g, () => at(g.player, 10, 6));
    expect(g.score).toBe(3 * DIG_POINTS);
    expect(isOpen(g.field, 9, 6, 1, 0)).toBe(true);
    until(g, () => g.player.c === 8, ["left"]);
    until(g, () => at(g.player, 7, 6));
    expect(g.score).toBe(3 * DIG_POINTS);
  });

  it("turns back at once mid-dig; the part cut stays dug, but shut to the monsters until it goes through", () => {
    const g = bare();
    hold(g, 10, "right");
    expect(position(g.player).x).toBeGreaterThan(7.4);
    hold(g, 1, "left");
    until(g, () => at(g.player, 7, 6));
    const part = dugFrom(g.field, 7, 6, 1, 0);
    expect(part).toBeGreaterThanOrEqual(5);
    expect(part).toBeLessThan(12);
    expect(isOpen(g.field, 7, 6, 1, 0)).toBe(false);
    expect(g.field.dug[cellOf(8, 6)]).toBe(0);
    expect(g.score).toBe(0);
    // Back in, the cut part goes by at running pace and the rest is dug.
    hold(g, 1, "right");
    until(g, () => at(g.player, 8, 6));
    expect(isOpen(g.field, 7, 6, 1, 0)).toBe(true);
    expect(g.score).toBe(DIG_POINTS);
  });

  it("walks the surface and digs down from it anywhere", () => {
    const g = bare();
    until(g, () => g.player.r === 0 && g.player.move === null, ["up"]);
    hold(g, 1, "left");
    until(g, () => at(g.player, 6, 0));
    until(g, () => g.player.c === 4, ["left"]);
    until(g, () => at(g.player, 3, 0));
    until(g, () => g.player.r === 1, ["down"]);
    until(g, () => at(g.player, 3, 2));
    expect(isOpen(g.field, 3, 0, 0, 1)).toBe(true);
    expect(isOpen(g.field, 3, 1, 0, 1)).toBe(true);
  });

  it("can't walk into a rock or off the field, but turns to face the way it pushes", () => {
    const g = bare();
    addRock(g, 8, 6);
    hold(g, 40, "right");
    expect(at(g.player, 7, 6)).toBe(true);
    expect(g.player.facing).toBe("right");
    hold(g, 1, "down");
    expect(g.player.facing).toBe("down");
    place(g, 0, 0);
    hold(g, 30, "left");
    expect(at(g.player, 0, 0)).toBe(true);
    expect(g.player.facing).toBe("left");
  });
});

describe("the harpoon", () => {
  it("flies the way the player faces, as far as it reaches, and comes back", () => {
    const g = bare();
    place(g, 7, 6, "up");
    requestPump(g);
    step(g, { dirs: [], pump: false });
    expect(g.harpoon?.phase).toBe("out");
    let longest = 0;
    const ticks = until(g, () => {
      longest = Math.max(longest, g.harpoon?.len ?? 0);
      return g.harpoon === null;
    });
    expect(longest).toBeCloseTo(PUMP_RANGE, 5);
    expect(ticks).toBeLessThan(25);
  });

  it("holds the player still while it is out", () => {
    const g = bare();
    place(g, 7, 6, "up");
    requestPump(g);
    hold(g, 5, "up");
    expect(at(g.player, 7, 6)).toBe(true);
  });

  it("stops at dirt", () => {
    const g = bare();
    requestPump(g);
    step(g, { dirs: [], pump: false });
    let longest = 0;
    until(g, () => {
      longest = Math.max(longest, g.harpoon?.len ?? 0);
      return g.harpoon === null;
    });
    expect(longest).toBeGreaterThan(0.3);
    expect(longest).toBeLessThan(0.5);
  });

  it("hooks a monster along the tunnel, and holding the pump blows it up until it pops", () => {
    const g = bare();
    across(g, 6, 7, 10);
    const m = addMonster(g, "pooka", 10, 6);
    hold(g, 20);
    requestPump(g);
    step(g, { dirs: [], pump: true });
    until(g, () => g.harpoon?.phase === "hooked");
    expect(m.inflate).toBe(1);
    pumpFor(g, 80);
    expect(m.mode).toBe("dead");
    expect(g.popped).toBe(1);
    expect(g.score).toBe(POP_POINTS[layerOf(6)]);
    expect(g.status).toBe("play");
  });

  it("pops with separate taps as well, each one size", () => {
    const g = bare();
    across(g, 6, 7, 9);
    const m = addMonster(g, "pooka", 9, 6);
    requestPump(g);
    until(g, () => g.harpoon?.phase === "hooked");
    for (let size = 2; size <= INFLATE_MAX; size++) {
      hold(g, 8);
      requestPump(g);
      step(g, { dirs: [], pump: false });
      expect(m.inflate).toBe(size);
    }
    until(g, () => m.mode === "dead");
  });

  it("is worth double for a Fygar pumped from the side, and the layer's price from above", () => {
    const side = bare();
    across(side, 9, 4, 7);
    down(side, 7, 6, 9);
    const f1 = addMonster(side, "fygar", 5, 9);
    f1.fireT = 1e6;
    place(side, 7, 9, "left");
    requestPump(side);
    until(side, () => side.harpoon?.phase === "hooked");
    pumpFor(side, 80);
    expect(f1.mode).toBe("dead");
    expect(side.score).toBe(2 * POP_POINTS[layerOf(9)]);

    const above = bare();
    const f2 = addMonster(above, "fygar", 7, 6);
    f2.fireT = 1e6;
    place(above, 7, 3, "down");
    requestPump(above);
    until(above, () => above.harpoon?.phase === "hooked");
    pumpFor(above, 80);
    expect(f2.mode).toBe("dead");
    expect(above.score).toBe(POP_POINTS[layerOf(Math.round(f2.y))]);
  });

  it("lets go when the player moves; the monster shrinks back a size at a time and walks again", () => {
    const g = bare();
    across(g, 6, 7, 10);
    const m = addMonster(g, "pooka", 10, 6);
    requestPump(g);
    until(g, () => g.harpoon?.phase === "hooked");
    hold(g, 1, "up");
    expect(g.harpoon).toBeNull();
    expect(m.inflate).toBe(1);
    until(g, () => m.inflate === 0, [], 200);
    const x = m.x;
    hold(g, 40);
    expect(m.x).not.toBe(x);
  });

  it("can't reach a monster through dirt, or catch a ghost", () => {
    const g = bare();
    across(g, 6, 7, 8);
    const walled = addMonster(g, "pooka", 9, 6);
    walled.c = 9;
    requestPump(g);
    until(g, () => g.harpoon === null);
    expect(walled.inflate).toBe(0);

    const h = bare();
    across(h, 6, 7, 10);
    const ghost = addMonster(h, "pooka", 9, 6);
    ghost.mode = "ghost";
    ghost.ghostFor = -1e6;
    ghost.x = 9;
    ghost.y = 6;
    requestPump(h);
    step(h, { dirs: [], pump: false });
    expect(h.harpoon?.phase).toBe("out");
    hold(h, 3);
    expect(ghost.inflate).toBe(0);
  });
});

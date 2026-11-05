import { describe, expect, it } from "vitest";
import { FIRE_CHARGE_TICKS, FLEE_DELAY, hurryAt } from "@/lib/game/constants";
import { respawn, step } from "@/lib/game/engine";
import { cellOf, isOpen } from "@/lib/game/field";
import { inFlame, walkSpeed } from "@/lib/game/monsters";
import { across, addMonster, at, bare, hold, place, until } from "./helpers";

describe("monsters in the tunnels", () => {
  it("follow a tunnel to the player and catch it", () => {
    const g = bare();
    across(g, 6, 2, 7);
    addMonster(g, "pooka", 2, 6);
    const ticks = until(g, () => g.status === "dying");
    expect(g.deathCause).toBe("monster");
    expect(ticks).toBeLessThan(160);
  });

  it("wander a tunnel that leads nowhere, staying in it", () => {
    const g = bare();
    across(g, 10, 2, 5);
    const m = addMonster(g, "pooka", 3, 10);
    const seen = new Set<number>();
    for (let t = 0; t < 600; t++) {
      step(g, { dirs: [], pump: false });
      expect(m.y).toBe(10);
      expect(m.x).toBeGreaterThanOrEqual(2);
      expect(m.x).toBeLessThanOrEqual(5);
      seen.add(Math.round(m.x));
    }
    expect(seen.size).toBe(4);
  });

  it("are harmless while blown up", () => {
    const g = bare();
    across(g, 6, 6, 7);
    const m = addMonster(g, "pooka", 6, 6);
    m.inflate = 2;
    m.deflateT = 1e6;
    hold(g, 60);
    expect(g.status).toBe("play");
  });

  it("hurry once the round runs long", () => {
    const g = bare();
    const calm = walkSpeed(g);
    g.time = hurryAt(1) - 1;
    step(g, { dirs: [], pump: false });
    expect(g.hurry).toBe(true);
    expect(g.events.some((e) => e.kind === "hurry")).toBe(true);
    expect(walkSpeed(g)).toBeGreaterThan(calm);
  });
});

describe("ghosts", () => {
  it("drift off when their time comes, through the dirt, and come down into the first tunnel they cross", () => {
    const g = bare();
    across(g, 10, 2, 4);
    across(g, 8, 1, 6);
    place(g, 7, 6);
    const m = addMonster(g, "pooka", 3, 10);
    m.ghostAt = 30;
    until(g, () => m.mode === "ghost");
    expect(g.events.some((e) => e.kind === "ghost")).toBe(true);
    until(g, () => m.mode === "tunnel");
    expect(m.r).toBe(8);
    expect(g.field.dug[cellOf(m.c, m.r)]).toBe(1);
    expect(m.x).toBe(m.c);
  });

  it("kill the player they reach", () => {
    const g = bare();
    const m = addMonster(g, "pooka", 3, 10);
    m.ghostAt = 0;
    until(g, () => g.status === "dying");
    expect(g.deathCause).toBe("ghost");
  });
});

describe("Fygars", () => {
  it("glow, then breathe fire through the dirt at the player in their row", () => {
    const g = bare();
    const f = addMonster(g, "fygar", 5, 6);
    f.fireT = 0;
    until(g, () => f.fire !== null);
    expect(f.fire?.dir).toBe(1);
    expect(g.events.some((e) => e.kind === "charge")).toBe(true);
    const ticks = until(g, () => g.status === "dying");
    expect(ticks).toBeGreaterThanOrEqual(FIRE_CHARGE_TICKS);
    expect(g.deathCause).toBe("fire");
  });

  it("reach only as far as the flame goes", () => {
    const g = bare();
    const f = addMonster(g, "fygar", 2, 6);
    f.fire = { phase: "breath", t: 20, dir: 1 };
    expect(inFlame(f, 4.5, 6)).toBe(true);
    expect(inFlame(f, 7, 6)).toBe(false);
    expect(inFlame(f, 4.5, 7)).toBe(false);
    expect(inFlame(f, 1, 6)).toBe(false);
    f.fire = { phase: "charge", t: 20, dir: 1 };
    expect(inFlame(f, 3, 6)).toBe(false);
  });
});

describe("the last monster", () => {
  it("runs for the surface and off the left edge, worth nothing, and the round ends", () => {
    const g = bare();
    g.monsters[1].mode = "dead";
    const m = g.monsters[0];
    until(g, () => m.mode === "flee", [], FLEE_DELAY + 5);
    until(g, () => m.y === 0);
    until(g, () => g.status === "clear");
    expect(m.mode).toBe("escaped");
    expect(g.score).toBe(0);
  });
});

describe("losing a life", () => {
  it("sends the monsters home and keeps the tunnels", () => {
    const g = bare();
    across(g, 6, 2, 7);
    const m = addMonster(g, "pooka", 2, 6);
    hold(g, 1, "up");
    until(g, () => at(g.player, 7, 5));
    hold(g, 1, "down");
    until(g, () => g.status === "dying");
    until(g, () => g.status === "dead");
    respawn(g);
    expect(g.status).toBe("play");
    expect(at(g.player, 7, 6)).toBe(true);
    expect(at(m, 2, 6)).toBe(true);
    expect(m.x).toBe(2);
    expect(isOpen(g.field, 2, 6, 1, 0)).toBe(true);
    expect(g.time).toBe(0);
  });
});

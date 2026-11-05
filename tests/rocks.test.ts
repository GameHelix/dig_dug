import { describe, expect, it } from "vitest";
import {
  CRUSH_POINTS,
  DEATH_TICKS,
  DIG_POINTS,
  ROCK_CRUMBLE_TICKS,
  ROCK_LOOSE_TICKS,
  VEG_TICKS,
  VEGGIES,
} from "@/lib/game/constants";
import { respawn } from "@/lib/game/engine";
import { cellOf, isOpen } from "@/lib/game/field";
import { addMonster, addRock, at, bare, down, hold, place, until } from "./helpers";

describe("rocks", () => {
  it("wait while the player holds them up, wobble once it moves on, then drop and break up", () => {
    const g = bare();
    const k = addRock(g, 8, 5);
    hold(g, 1, "right");
    until(g, () => at(g.player, 8, 6));
    hold(g, 120);
    expect(k.phase).toBe("set");
    hold(g, 1, "right");
    until(g, () => k.phase === "loose");
    expect(g.player.c).toBe(8);
    until(g, () => k.phase === "fall", [], ROCK_LOOSE_TICKS + 1);
    until(g, () => k.phase === "crumble");
    expect(k.r).toBe(6);
    expect(g.events.some((e) => e.kind === "land")).toBe(true);
    until(g, () => !g.rocks.includes(k), [], ROCK_CRUMBLE_TICKS + 1);
    // The hole it left is open tunnel.
    expect(isOpen(g.field, 8, 5, 0, 1)).toBe(true);
    expect(g.rocksDropped).toBe(1);
    expect(g.status).toBe("play");
  });

  it("are walls to everything walking until they break up", () => {
    const g = bare();
    addRock(g, 7, 7);
    hold(g, 30, "down");
    expect(at(g.player, 7, 6)).toBe(true);
  });

  it("crush what they come down on: a thousand for one monster", () => {
    const g = bare();
    addRock(g, 3, 3);
    down(g, 3, 4, 9);
    const m = addMonster(g, "pooka", 3, 8);
    until(g, () => m.mode === "crushed");
    until(g, () => g.rocks.every((k) => k.phase === "crumble"));
    expect(g.score).toBe(CRUSH_POINTS[1]);
    expect(g.crushed).toBe(1);
    until(g, () => m.mode === "dead", [], ROCK_CRUMBLE_TICKS + 1);
  });

  it("are worth more the more they take: 2,500 for two", () => {
    const g = bare();
    addRock(g, 3, 3);
    down(g, 3, 4, 10);
    addMonster(g, "pooka", 3, 7);
    addMonster(g, "fygar", 3, 9).fireT = 1e6;
    until(g, () => g.rocks.every((k) => k.phase === "crumble"));
    expect(g.crushed).toBe(2);
    expect(g.score).toBe(CRUSH_POINTS[2]);
  });

  it("crush the player too, and stay where he lies until the next life", () => {
    const g = bare();
    const k = addRock(g, 3, 2);
    down(g, 3, 3, 9);
    place(g, 3, 8);
    until(g, () => g.status === "dying");
    expect(g.deathCause).toBe("rock");
    until(g, () => g.status === "dead", [], DEATH_TICKS + 1);
    expect(g.rocks).toContain(k);
    expect(k.player).toBe(true);
    respawn(g);
    expect(g.rocks).not.toContain(k);
    expect(g.status).toBe("play");
  });

  it("bring out the bonus vegetable once two have dropped; it scores by round and goes after ten seconds", () => {
    const g = bare();
    addRock(g, 2, 3);
    down(g, 2, 4, 6);
    addRock(g, 12, 3);
    down(g, 12, 4, 6);
    place(g, 7, 2);
    until(g, () => g.rocksDropped === 2);
    expect(g.veg).not.toBeNull();
    expect(g.veg?.cell).toBe(cellOf(7, 6));
    const before = g.score;
    until(g, () => g.veg === null, ["down"]);
    expect(g.score - before).toBe(VEGGIES[0].points);
    expect(g.events.some((e) => e.kind === "bonus")).toBe(true);

    const h = bare();
    addRock(h, 2, 3);
    down(h, 2, 4, 6);
    addRock(h, 12, 3);
    down(h, 12, 4, 6);
    place(h, 7, 1);
    until(h, () => h.rocksDropped === 2);
    hold(h, VEG_TICKS);
    expect(h.veg).toBeNull();
    expect(h.score).toBe(0);
    expect(h.vegShown).toBe(true);
  });

  it("don't give points for dirt they only fall through", () => {
    const g = bare();
    addRock(g, 3, 3);
    down(g, 3, 4, 6);
    until(g, () => g.rocks.length === 0);
    expect(g.score).toBe(0);
    expect(DIG_POINTS).toBeGreaterThan(0);
  });
});

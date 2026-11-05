import { describe, expect, it } from "vitest";
import { DELTA, openAt, position } from "@/lib/game/board";
import { PUMP_RANGE, START_LIVES } from "@/lib/game/constants";
import { createGame, requestPump, respawn, step, type Game } from "@/lib/game/engine";
import type { Difficulty, Dir, Input } from "@/lib/game/types";

/** Whether the harpoon would fly clear from (x0, y0) to (x1, y1). */
function clearLine(g: Game, x0: number, y0: number, x1: number, y1: number): boolean {
  const n = Math.ceil(Math.hypot(x1 - x0, y1 - y0) / 0.1);
  for (let i = 1; i <= n; i++) {
    if (!openAt(g, x0 + ((x1 - x0) * i) / n, y0 + ((y1 - y0) * i) / n)) return false;
  }
  return true;
}

/**
 * A plain, careless player: pump whatever is lined up in reach, back off from
 * anything close it can't shoot, else dig towards the nearest monster. It
 * knows nothing of fire or rocks, so it dies plenty — which is the point:
 * even this much play clears rounds.
 */
function autopilot(g: Game): Input {
  const h = g.harpoon;
  if (h?.phase === "hooked") return { dirs: [], pump: true };
  if (h) return { dirs: [], pump: false };
  const a = g.player;
  const p = position(a);
  for (const m of g.monsters) {
    if (m.mode !== "tunnel" && !(m.mode === "flee" && m.y <= 0)) continue;
    const dx = m.x - p.x;
    const dy = m.y - p.y;
    let dir: Dir | null = null;
    if (Math.abs(dy) < 0.3 && Math.abs(dx) <= PUMP_RANGE + 0.2) dir = dx < 0 ? "left" : "right";
    else if (Math.abs(dx) < 0.3 && Math.abs(dy) <= PUMP_RANGE + 0.2) dir = dy < 0 ? "up" : "down";
    if (!dir) continue;
    const [ux, uy] = DELTA[dir];
    const reach = Math.max(0, Math.hypot(dx, dy) - 0.45);
    if (!clearLine(g, p.x, p.y, p.x + ux * reach, p.y + uy * reach)) continue;
    if (a.facing === dir) {
      requestPump(g);
      return { dirs: [], pump: true };
    }
    return { dirs: [dir], pump: false };
  }
  for (const m of g.monsters) {
    if ((m.mode !== "tunnel" && m.mode !== "ghost" && m.mode !== "flee") || m.inflate > 0) continue;
    if (Math.hypot(m.x - p.x, m.y - p.y) >= (m.mode === "ghost" ? 2.2 : 1.6)) continue;
    const dx = p.x - m.x;
    const dy = p.y - m.y;
    const across: Dir = dx >= 0 ? "right" : "left";
    const upDown: Dir = dy >= 0 ? "down" : "up";
    return { dirs: Math.abs(dx) >= Math.abs(dy) ? [across, upDown] : [upDown, across], pump: false };
  }
  const targets = g.monsters.filter((m) => m.mode === "tunnel" || (m.mode === "flee" && m.y <= 0));
  if (targets.length === 0) return { dirs: [], pump: false };
  const far = (m: (typeof targets)[number]) => Math.abs(m.x - p.x) + Math.abs(m.y - p.y);
  const target = targets.reduce((best, m) => (far(m) < far(best) ? m : best));
  const dx = target.x - p.x;
  const dy = target.y - p.y;
  const dirs: Dir[] = [];
  if (Math.abs(dy) > 0.2 && Math.abs(dy) <= Math.abs(dx)) dirs.push(dy < 0 ? "up" : "down");
  if (Math.abs(dx) > 0.2) dirs.push(dx < 0 ? "left" : "right");
  if (Math.abs(dy) > 0.2 && Math.abs(dy) > Math.abs(dx)) dirs.push(dy < 0 ? "up" : "down");
  return { dirs, pump: false };
}

/** Play one round on three lives with the autopilot; whether it was cleared. */
function playRound(round: number, difficulty: Difficulty, seed: number): boolean {
  const g = createGame(round, difficulty, seed);
  let lives = START_LIVES;
  for (let t = 0; t < 60 * 60 * 5; t++) {
    step(g, autopilot(g));
    g.events.length = 0;
    if (g.status === "clear") return true;
    if (g.status === "dead") {
      if (--lives === 0) return false;
      respawn(g);
    }
  }
  return false;
}

describe("playing it through", () => {
  it.each([1, 2, 3])("round %i can be cleared by plain play on most tries", (round) => {
    let cleared = 0;
    for (let seed = 1; seed <= 12; seed++) if (playRound(round, "classic", seed)) cleared++;
    expect(cleared).toBeGreaterThanOrEqual(5);
  });
});

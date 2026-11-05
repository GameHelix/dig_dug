import { describe, expect, it } from "vitest";
import { START_LIVES, TICK_HZ } from "@/lib/game/constants";
import { Run, type RunResult, type Voice } from "@/lib/run";

/** Feed the run animation frames for `seconds` of wall time. */
function frames(run: Run, seconds: number, from = { t: 0 }): void {
  const step = 1000 / TICK_HZ;
  for (let i = 0; i < seconds * TICK_HZ; i++) {
    from.t += step;
    run.frame(from.t);
  }
}

function connect(run: Run) {
  const voices: Voice[] = [];
  const cleared: number[] = [];
  const results: RunResult[] = [];
  run.connect({
    sound: (v) => voices.push(v),
    cleared: (round) => cleared.push(round),
    over: (r) => results.push(r),
  });
  return { voices, cleared, results };
}

/** Take every monster out of the round. */
function clearRound(run: Run): void {
  for (const m of run.game.monsters) m.mode = "dead";
}

describe("a run", () => {
  it("waits on each round until the person moves", () => {
    const run = new Run("classic", 1);
    const { voices } = connect(run);
    const clock = { t: 0 };
    frames(run, 1, clock);
    expect(run.getView().phase).toBe("ready");
    expect(run.game.clock).toBe(0);
    run.press("left");
    frames(run, 1, clock);
    expect(run.getView().phase).toBe("play");
    expect(run.game.clock).toBeGreaterThan(50);
    expect(voices).toContain("start");
  });

  it("starts on the pump button too, firing the harpoon", () => {
    const run = new Run("classic", 1);
    const { voices } = connect(run);
    run.pump(true);
    run.pump(false);
    expect(run.phase).toBe("play");
    frames(run, 0.1);
    expect(voices).toEqual(["start", "shoot"]);
  });

  it("starts with three lives and gives another at 10,000 and at 40,000 and every 40,000 after", () => {
    const run = new Run("classic", 1);
    const { voices } = connect(run);
    const clock = { t: 0 };
    run.press("up");
    expect(run.lives).toBe(START_LIVES);
    run.game.score = 9_990;
    frames(run, 0.1, clock);
    expect(run.lives).toBe(START_LIVES);
    run.game.score = 10_000;
    frames(run, 0.1, clock);
    expect(run.lives).toBe(START_LIVES + 1);
    expect(voices).toContain("life");
    run.game.score = 39_000;
    frames(run, 0.1, clock);
    expect(run.lives).toBe(START_LIVES + 1);
    run.game.score = 80_000;
    frames(run, 0.1, clock);
    expect(run.lives).toBe(START_LIVES + 3);
  });

  it("banks a cleared round, shows the banner, then waits on the next round", () => {
    const run = new Run("classic", 1);
    const { cleared } = connect(run);
    const clock = { t: 0 };
    run.press("up");
    frames(run, 0.5, clock);
    run.game.score += 1234;
    const score = run.getView().score + 1234;
    clearRound(run);
    frames(run, 0.1, clock);
    const view = run.getView();
    expect(view.phase).toBe("cleared");
    expect(view.cleared?.round).toBe(1);
    expect(view.score).toBe(score);
    expect(cleared).toEqual([1]);
    frames(run, 3.1, clock);
    expect(run.getView().phase).toBe("ready");
    expect(run.getView().round).toBe(2);
    expect(run.getView().score).toBe(score);
    expect(run.game.round).toBe(2);
  });

  it("skips the banner on request", () => {
    const run = new Run("classic", 1);
    connect(run);
    run.press("up");
    frames(run, 0.2);
    clearRound(run);
    frames(run, 0.1);
    expect(run.phase).toBe("cleared");
    run.proceed();
    expect(run.phase).toBe("ready");
    expect(run.round).toBe(2);
  });

  it("costs a life for a death and waits again; with the last one gone the run is over", () => {
    const run = new Run("relentless", 1);
    const { results, voices } = connect(run);
    const clock = { t: 0 };
    run.press("up");
    frames(run, 0.2, clock);
    run.game.status = "dead";
    frames(run, 0.1, clock);
    expect(run.lives).toBe(START_LIVES - 1);
    expect(run.getView().phase).toBe("ready");
    expect(run.game.status).toBe("play");
    run.lives = 1;
    run.press("up");
    frames(run, 0.2, clock);
    run.game.score = 450;
    run.game.status = "dead";
    frames(run, 0.1, clock);
    expect(run.getView().phase).toBe("over");
    expect(voices).toContain("over");
    expect(results).toHaveLength(1);
    expect(results[0]).toMatchObject({ difficulty: "relentless", round: 1, cleared: 0 });
    expect(results[0].score).toBeGreaterThanOrEqual(450);
  });
});

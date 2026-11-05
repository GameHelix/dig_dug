import { FIRST_LIFE, LIFE_EVERY, MAX_LIVES, START_LIVES, TICK_HZ } from "./game/constants";
import { createGame, requestPump, respawn, step, type Game } from "./game/engine";
import type { Difficulty, Dir, GameEvent, MonsterKind } from "./game/types";

/*
 * One run: round after round on three lives, more for every 40,000 points.
 * It owns the live round, turns held keys into the engine's input, steps the
 * engine at a fixed 60 Hz from the view's animation frames, and tells the
 * React side what changed through a tiny external store. It has no React and
 * no DOM, and time only moves while the view calls `frame` — a hidden tab or
 * an open dialog simply stops calling it.
 */

export type Phase = "ready" | "play" | "dying" | "cleared" | "over";

export type Voice = GameEvent["kind"] | "start" | "over" | "life";

/** A flash on the field — a burst, a sparkle, points floating up — drawn for a moment where it happened. */
export interface Effect {
  kind: "pop" | "bonus" | "points";
  x: number;
  y: number;
  /** The run's tick it happened on. */
  t0: number;
  /** Points to float up, if any. */
  points: number;
  /** Whose colours a burst takes. */
  tint: MonsterKind | "veg";
}

export interface Cleared {
  round: number;
  ticks: number;
  points: number;
  popped: number;
  crushed: number;
}

/** What the React side renders; replaced, never mutated, when it changes. */
export interface RunView {
  phase: Phase;
  round: number;
  score: number;
  lives: number;
  /** Monsters still in the round, of how many, and how many of those the round brought were Pookas. */
  left: number;
  total: number;
  pookas: number;
  hurry: boolean;
  cleared: Cleared | null;
}

export interface RunResult {
  score: number;
  difficulty: Difficulty;
  /** The round the run ended on. */
  round: number;
  /** Rounds cleared during the run. */
  cleared: number;
  popped: number;
  crushed: number;
}

export interface RunHandlers {
  sound: (voice: Voice) => void;
  /** A round was cleared. */
  cleared: (round: number) => void;
  over: (result: RunResult) => void;
}

/** How long the round-clear banner stays before the next round, unless skipped. */
const BANNER_TICKS = 3 * TICK_HZ;
/** Effects older than this are dropped. */
const EFFECT_TICKS = 70;
/** A long gap between frames (a stalled tab) never fast-forwards more than this. */
const MAX_TICKS_PER_FRAME = 8;

export class Run {
  readonly difficulty: Difficulty;
  round = 1;
  game: Game;
  lives = START_LIVES;
  phase: Phase = "ready";
  /** Points from rounds finished so far; the live round's add to them. */
  private banked = 0;
  private clearedCount = 0;
  private popped = 0;
  private crushed = 0;
  private cleared: Cleared | null = null;
  /** The score that brings the next extra life. */
  private nextLife = FIRST_LIFE;
  /** Bumped for every new round, so the renderer knows its cached field is stale. */
  serial = 0;
  /** Ticks of the run so far, the clock effects and animations run on. */
  ticks = 0;
  effects: Effect[] = [];

  private readonly seed: number;
  private held: Dir[] = [];
  private pumping = false;
  private bannerT = 0;
  private last = -1;
  private acc = 0;
  private view: RunView;
  private listeners = new Set<() => void>();
  private handlers: RunHandlers = { sound: () => {}, cleared: () => {}, over: () => {} };

  constructor(difficulty: Difficulty, seed: number) {
    this.difficulty = difficulty;
    this.seed = seed;
    this.game = this.newGame();
    this.view = this.makeView();
  }

  connect(handlers: RunHandlers): void {
    this.handlers = handlers;
  }

  subscribe = (fn: () => void): (() => void) => {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  };

  getView = (): RunView => this.view;

  /** The score so far, the live round's included. */
  get score(): number {
    return this.banked + (this.phase === "cleared" || this.phase === "over" ? 0 : this.game.score);
  }

  /** Whether the pump button is held, for the sprite. */
  get pumpHeld(): boolean {
    return this.pumping;
  }

  /* ------------------------------------------------------------ input */

  /** A direction pressed: it goes to the front of the held keys, and a waiting round starts. */
  press(dir: Dir): void {
    this.held = [dir, ...this.held.filter((d) => d !== dir)];
    if (this.phase === "ready") this.begin();
  }

  release(dir: Dir): void {
    this.held = this.held.filter((d) => d !== dir);
  }

  releaseAll(): void {
    this.held = [];
    this.pumping = false;
  }

  /** The pump button pressed or let go: a press fires the harpoon or pumps, holding keeps pumping. */
  pump(down: boolean): void {
    this.pumping = down;
    if (!down) return;
    if (this.phase === "ready") this.begin();
    if (this.phase === "play") requestPump(this.game);
  }

  /** Enter or a tap: starts a waiting round, or moves on from the round-clear banner. */
  proceed(): void {
    if (this.phase === "ready") this.begin();
    else if (this.phase === "cleared") this.next();
  }

  /* ------------------------------------------------------------- time */

  /** Called every animation frame with the frame's timestamp, in milliseconds. */
  frame(now: number): void {
    if (this.last < 0) this.last = now;
    this.acc += Math.min(0.25, Math.max(0, (now - this.last) / 1000));
    this.last = now;
    const tick = 1 / TICK_HZ;
    let n = 0;
    while (this.acc >= tick && n < MAX_TICKS_PER_FRAME) {
      this.acc -= tick;
      this.tick();
      n++;
    }
    if (n === MAX_TICKS_PER_FRAME) this.acc = 0;
    this.publish();
  }

  /** After a pause, forget the time that passed while it lasted. */
  resume(): void {
    this.last = -1;
    this.acc = 0;
  }

  private tick(): void {
    if (this.phase === "ready" || this.phase === "over") return;
    this.ticks++;
    if (this.effects.length > 0 && this.ticks - this.effects[0].t0 > EFFECT_TICKS) {
      this.effects = this.effects.filter((e) => this.ticks - e.t0 <= EFFECT_TICKS);
    }
    if (this.phase === "cleared") {
      if (++this.bannerT >= BANNER_TICKS) this.next();
      return;
    }
    step(this.game, { dirs: this.held, pump: this.pumping });
    this.drain();
    this.award();
    const status = this.game.status;
    if (status === "dying") this.phase = "dying";
    else if (status === "dead") this.lose();
    else if (status === "clear") this.win();
  }

  private drain(): void {
    for (const e of this.game.events) {
      this.handlers.sound(e.kind);
      if (e.kind === "pop") {
        const tint = this.game.monsters[e.id]?.kind ?? "pooka";
        this.effects.push({ kind: "pop", x: e.x, y: e.y, t0: this.ticks, points: e.points, tint });
      } else if (e.kind === "land" && e.points > 0) {
        this.effects.push({ kind: "points", x: e.x, y: e.y + 0.3, t0: this.ticks, points: e.points, tint: "veg" });
      } else if (e.kind === "bonus") {
        this.effects.push({ kind: "bonus", x: e.x, y: e.y, t0: this.ticks, points: e.points, tint: "veg" });
      }
    }
    this.game.events.length = 0;
  }

  /** An extra life at 10,000, then at 40,000 and every 40,000 after. */
  private award(): void {
    const total = this.banked + this.game.score;
    while (total >= this.nextLife) {
      if (this.lives < MAX_LIVES) {
        this.lives++;
        this.handlers.sound("life");
      }
      this.nextLife = this.nextLife < LIFE_EVERY ? LIFE_EVERY : this.nextLife + LIFE_EVERY;
    }
  }

  /* ----------------------------------------------------------- rounds */

  private newGame(): Game {
    this.serial++;
    return createGame(this.round, this.difficulty, `${this.seed}:${this.round}:${this.serial}`);
  }

  private begin(): void {
    this.phase = "play";
    this.handlers.sound("start");
  }

  private lose(): void {
    this.lives--;
    if (this.lives <= 0) {
      this.finish();
      return;
    }
    respawn(this.game);
    this.effects = [];
    this.phase = "ready";
  }

  private win(): void {
    const g = this.game;
    this.banked += g.score;
    this.popped += g.popped;
    this.crushed += g.crushed;
    this.clearedCount++;
    this.cleared = { round: this.round, ticks: g.clock, points: g.score, popped: g.popped, crushed: g.crushed };
    this.phase = "cleared";
    this.bannerT = 0;
    this.handlers.cleared(this.round);
  }

  private next(): void {
    this.round++;
    this.game = this.newGame();
    this.effects = [];
    this.cleared = null;
    this.phase = "ready";
  }

  private finish(): void {
    const g = this.game;
    this.banked += g.score;
    this.popped += g.popped;
    this.crushed += g.crushed;
    this.phase = "over";
    this.handlers.sound("over");
    this.publish();
    this.handlers.over({
      score: this.banked,
      difficulty: this.difficulty,
      round: this.round,
      cleared: this.clearedCount,
      popped: this.popped,
      crushed: this.crushed,
    });
  }

  /* ------------------------------------------------------------- view */

  private makeView(): RunView {
    const g = this.game;
    let left = 0;
    let pookas = 0;
    for (const m of g.monsters) {
      if (m.mode !== "dead" && m.mode !== "escaped") left++;
      if (m.kind === "pooka") pookas++;
    }
    return {
      phase: this.phase,
      round: this.round,
      score: this.score,
      lives: this.lives,
      left,
      total: g.monsters.length,
      pookas,
      hurry: g.hurry,
      cleared: this.phase === "cleared" ? this.cleared : null,
    };
  }

  private publish(): void {
    const next = this.makeView();
    const v = this.view;
    if (
      next.phase === v.phase &&
      next.round === v.round &&
      next.score === v.score &&
      next.lives === v.lives &&
      next.left === v.left &&
      next.total === v.total &&
      next.pookas === v.pookas &&
      next.hurry === v.hurry &&
      next.cleared === v.cleared
    ) {
      return;
    }
    this.view = next;
    this.listeners.forEach((fn) => fn());
  }
}

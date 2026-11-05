import { advance, DELTA, openAt, playerCell, position, rockAt, rockNear } from "./board";
import {
  COLS,
  CRUSH_POINTS,
  DEATH_TICKS,
  DEFLATE_TICKS,
  DIG_POINTS,
  FLEE_DELAY,
  hurryAt,
  INFLATE_MAX,
  PLAYER_DIG,
  PLAYER_RUN,
  POP_POINTS,
  PUMP_BACK,
  PUMP_GAP,
  PUMP_RANGE,
  PUMP_REPEAT,
  PUMP_SPEED,
  ROCK_CRUMBLE_TICKS,
  ROCK_FALL,
  ROCK_LOOSE_TICKS,
  ROWS,
  START_COL,
  START_ROW,
  SUB,
  TOUCH,
  VEG_AFTER_ROCKS,
  VEG_TICKS,
  VEGGIES,
  vegIndex,
} from "./constants";
import { cellOf, cloneField, colOf, cut, dugFrom, isOpen, layerOf, openWay, rowOf, tunnelSteps, type Field } from "./field";
import { makeLayout, type Layout } from "./layout";
import { hookable, inFlame, newMonster, resetMonster, startFlee, updateMonster } from "./monsters";
import { makeRng, type Rng } from "./rng";
import type {
  DeathCause,
  Difficulty,
  Dir,
  GameEvent,
  GameStatus,
  Harpoon,
  Input,
  Monster,
  Move,
  Player,
  Rock,
  Veg,
} from "./types";

/*
 * One round in play: the field, the player, the monsters and the rocks, moved
 * on by `step` one fixed tick at a time. It is plain mutable data with no
 * clock of its own — the view drives it, draws it and drains `events` for
 * sounds — and it is seeded, so the same inputs always play out the same way,
 * which is what the tests lean on.
 */

export interface Game {
  round: number;
  difficulty: Difficulty;
  layout: Layout;
  field: Field;
  player: Player;
  harpoon: Harpoon | null;
  /** A pump asked for and not used yet. */
  pumpQueued: boolean;
  monsters: Monster[];
  rocks: Rock[];
  rocksDropped: number;
  veg: Veg | null;
  /** The vegetable has shown this round; it comes once. */
  vegShown: boolean;
  status: GameStatus;
  /** Ticks of play since this life started; the monsters hurry when it runs long. */
  time: number;
  /** Ticks of play in the round. */
  clock: number;
  hurry: boolean;
  /** Ticks into the player's death. */
  deathT: number;
  deathCause: DeathCause | null;
  /** Bumped whenever the tunnels change, so the view knows to redraw them. */
  terrain: number;
  /** Points scored in this round. */
  score: number;
  popped: number;
  crushed: number;
  /** Steps along the tunnels from each cell to the player; -1 where there is no way. */
  dist: Int16Array;
  events: GameEvent[];
  rng: Rng;
}

function newPlayer(): Player {
  return { c: START_COL, r: START_ROW, move: null, acc: 0, steps: 0, facing: "right", side: 1 };
}

export function createGame(round: number, difficulty: Difficulty, seed: number | string = 1): Game {
  const layout = makeLayout(round);
  const g: Game = {
    round,
    difficulty,
    layout,
    field: cloneField(layout.field),
    player: newPlayer(),
    harpoon: null,
    pumpQueued: false,
    monsters: layout.monsters.map((m, id) => newMonster(id, m.kind, m.cell)),
    rocks: layout.rocks.map((cell, id) => ({
      id,
      c: colOf(cell),
      r: rowOf(cell),
      y: rowOf(cell),
      phase: "set",
      t: 0,
      crushed: [],
      player: false,
    })),
    rocksDropped: 0,
    veg: null,
    vegShown: false,
    status: "play",
    time: 0,
    clock: 0,
    hurry: false,
    deathT: 0,
    deathCause: null,
    terrain: 0,
    score: 0,
    popped: 0,
    crushed: 0,
    dist: new Int16Array(COLS * ROWS).fill(-1),
    events: [],
    rng: makeRng(seed),
  };
  for (const m of g.monsters) resetMonster(g, m);
  refreshTrail(g);
  return g;
}

/** Advance the round one tick. */
export function step(g: Game, input: Input): void {
  if (g.status === "dying") {
    // A rock that caught the player carries on down; everything else holds still.
    updateRocks(g);
    if (++g.deathT >= DEATH_TICKS) g.status = "dead";
    return;
  }
  if (g.status !== "play") return;
  g.time++;
  g.clock++;
  if (!g.hurry && g.time >= hurryAt(g.round)) {
    g.hurry = true;
    g.events.push({ kind: "hurry" });
  }
  updateRocks(g);
  if (g.status !== "play") return;
  // The harpoon first: once it is out, the player stays put.
  updateHarpoon(g, input);
  updatePlayer(g, input);
  refreshTrail(g);
  for (const m of g.monsters) updateMonster(g, m);
  updateLast(g);
  updateVeg(g);
  if (caught(g)) return;
  if (g.monsters.every((m) => m.mode === "dead" || m.mode === "escaped")) {
    g.status = "clear";
    g.events.push({ kind: "clear" });
  }
}

/** Ask for a pump: fires the harpoon, or blows up whatever is on it. */
export function requestPump(g: Game): void {
  if (g.status === "play") g.pumpQueued = true;
}

/**
 * The next life after a death: the player back at the foot of the shaft, the
 * monsters still in the round back where they began. The tunnels stay dug,
 * and whatever the rocks have done stays done.
 */
export function respawn(g: Game): void {
  if (g.status !== "dead") return;
  g.status = "play";
  g.deathT = 0;
  g.deathCause = null;
  g.time = 0;
  g.hurry = false;
  g.harpoon = null;
  g.pumpQueued = false;
  g.player = newPlayer();
  for (const k of g.rocks) {
    k.player = false;
    if (k.phase === "crumble") breakUp(g, k);
  }
  g.rocks = g.rocks.filter((k) => k.phase !== "crumble");
  for (const m of g.monsters) {
    if (m.mode === "tunnel" || m.mode === "ghost" || m.mode === "flee") resetMonster(g, m);
  }
  refreshTrail(g);
}

/* ------------------------------------------------------------- player */

function updatePlayer(g: Game, input: Input): void {
  const a = g.player;
  const h = g.harpoon;
  if (h) {
    // The harpoon holds the player still; pressing a way lets go of whatever is on it.
    if (h.phase !== "hooked" || input.dirs.length === 0) return;
    letGo(g);
  }
  turnBack(a, input);
  advance(
    a,
    (m) => playerSpeed(g, m),
    () => decidePlayer(g, input),
    (m) => dig(g, m),
    () => {}
  );
}

function face(a: Player, dir: Dir): void {
  a.facing = dir;
  if (dir === "left") a.side = -1;
  else if (dir === "right") a.side = 1;
}

/** Pressing the opposite way mid-move turns back at once instead of finishing the step. */
function turnBack(a: Player, input: Input): void {
  const m = a.move;
  if (!m || input.dirs.length === 0) return;
  const [dc, dr] = DELTA[input.dirs[0]];
  if (dc !== -m.dc || dr !== -m.dr) return;
  a.c += m.dc;
  a.r += m.dr;
  m.dc = dc;
  m.dr = dr;
  m.p = SUB - m.p;
  face(a, input.dirs[0]);
}

/** The first held way that leads somewhere: anywhere in the field but into a rock. Pushing still turns the player. */
function decidePlayer(g: Game, input: Input): Move | null {
  const a = g.player;
  for (const dir of input.dirs) {
    const [dc, dr] = DELTA[dir];
    const c = a.c + dc;
    const r = a.r + dr;
    if (c < 0 || c >= COLS || r < 0 || r >= ROWS || rockAt(g, c, r)) continue;
    face(a, dir);
    return { dc, dr, p: 0 };
  }
  if (input.dirs.length > 0) face(a, input.dirs[0]);
  return null;
}

/**
 * Whether sub-step `p` of the player's move, counted from the cell it left,
 * is in dirt nobody has cut: past the part dug from this end and short of
 * the part dug from the far one.
 */
function intoDirt(g: Game, m: Move, p: number): boolean {
  const a = g.player;
  const f = g.field;
  if (isOpen(f, a.c, a.r, m.dc, m.dr)) return false;
  const near = dugFrom(f, a.c, a.r, m.dc, m.dr);
  const far = dugFrom(f, a.c + m.dc, a.r + m.dr, -m.dc, -m.dr);
  return p > near && p <= SUB - far;
}

/** Slower while the next sub-step cuts new dirt; the full pace along a tunnel or a part already cut. */
function playerSpeed(g: Game, m: Move): number {
  return intoDirt(g, m, m.p + 1) ? PLAYER_DIG : PLAYER_RUN;
}

/** Each sub-step into dirt cuts the way a little further; reaching a new cell's centre scores. */
function dig(g: Game, m: Move): void {
  if (!intoDirt(g, m, m.p)) return;
  const a = g.player;
  const f = g.field;
  const far = cellOf(a.c + m.dc, a.r + m.dr);
  const fresh = f.dug[far] === 0;
  if (!cut(f, a.c, a.r, m.dc, m.dr, m.p)) return;
  g.terrain++;
  if (fresh && f.dug[far] === 1) {
    g.score += DIG_POINTS;
    g.events.push({ kind: "dig" });
  }
}

/* ------------------------------------------------------------ harpoon */

function updateHarpoon(g: Game, input: Input): void {
  const h = g.harpoon;
  if (!h) {
    if (g.pumpQueued) {
      g.pumpQueued = false;
      shoot(g);
    }
    return;
  }
  if (h.phase === "out") {
    reachOut(g, h);
  } else if (h.phase === "back") {
    g.pumpQueued = false;
    h.len -= PUMP_BACK;
    if (h.len <= 0) g.harpoon = null;
  } else {
    const m = g.monsters[h.target];
    if (!m || !hookable(m)) {
      g.harpoon = null;
      return;
    }
    h.since++;
    if (g.pumpQueued ? h.since >= PUMP_GAP : input.pump && h.since >= PUMP_REPEAT) {
      g.pumpQueued = false;
      pumpUp(g, m, h);
    }
  }
}

function shoot(g: Game): void {
  const p = position(g.player);
  g.harpoon = { dir: g.player.facing, x: p.x, y: p.y, len: 0, phase: "out", target: -1, since: 0 };
  g.events.push({ kind: "shoot" });
}

/** The tip flies out a tick's worth, a twentieth of a cell at a time, so it never skips past dirt or a monster. */
function reachOut(g: Game, h: Harpoon): void {
  const [dx, dy] = DELTA[h.dir];
  const to = Math.min(PUMP_RANGE, h.len + PUMP_SPEED);
  while (h.len < to - 1e-9) {
    const d = Math.min(to, h.len + 0.05);
    const x = h.x + dx * d;
    const y = h.y + dy * d;
    if (!openAt(g, x, y) || rockNear(g, x, y)) {
      h.phase = "back";
      return;
    }
    h.len = d;
    const m = g.monsters.find((o) => hookable(o) && Math.abs(o.x - x) < 0.45 && Math.abs(o.y - y) < 0.45);
    if (m) {
      h.phase = "hooked";
      h.target = m.id;
      m.fire = null;
      g.events.push({ kind: "hook", id: m.id });
      pumpUp(g, m, h);
      return;
    }
  }
  if (h.len >= PUMP_RANGE - 1e-9) h.phase = "back";
}

/** One more pump: a size bigger, and at the last size it pops — worth double for a Fygar pumped from the side. */
function pumpUp(g: Game, m: Monster, h: Harpoon): void {
  m.inflate = Math.min(INFLATE_MAX, m.inflate + 1);
  m.deflateT = DEFLATE_TICKS;
  h.since = 0;
  g.events.push({ kind: "inflate", id: m.id, size: m.inflate });
  if (m.inflate < INFLATE_MAX) return;
  const sideways = h.dir === "left" || h.dir === "right";
  m.mode = "popping";
  m.popT = 0;
  m.move = null;
  m.points = POP_POINTS[layerOf(Math.round(m.y))] * (m.kind === "fygar" && sideways ? 2 : 1);
  h.phase = "back";
  h.target = -1;
}

/** Let go of a hooked monster: it starts to shrink back. */
function letGo(g: Game): void {
  const h = g.harpoon;
  if (h?.phase === "hooked") {
    const m = g.monsters[h.target];
    if (m) m.deflateT = DEFLATE_TICKS;
  }
  g.harpoon = null;
}

/* -------------------------------------------------------------- rocks */

function updateRocks(g: Game): void {
  for (const k of g.rocks) {
    if (k.phase === "set") {
      // Dirt gone from under it: it waits while the player holds it up, then wobbles.
      if (k.r + 1 < ROWS && g.field.dug[cellOf(k.c, k.r + 1)] && !holdsUp(g, k)) {
        k.phase = "loose";
        k.t = 0;
        g.events.push({ kind: "loose", rock: k.id });
      }
    } else if (k.phase === "loose") {
      if (++k.t >= ROCK_LOOSE_TICKS) {
        k.phase = "fall";
        k.t = 0;
        // The hole it sat in is open now, and so is the way down out of it.
        openWay(g.field, k.c, k.r, 0, 1);
        g.terrain++;
      }
    } else if (k.phase === "fall") {
      fall(g, k);
    } else if (++k.t >= ROCK_CRUMBLE_TICKS) {
      breakUp(g, k);
    }
  }
  // Dust is swept away, except where the player lies flattened: that stays until the next life.
  const swept = (k: Rock) => k.phase === "crumble" && k.t >= ROCK_CRUMBLE_TICKS && !k.player;
  if (g.rocks.some(swept)) g.rocks = g.rocks.filter((k) => !swept(k));
}

/** Whether the player is right under the rock, holding it up. */
function holdsUp(g: Game, k: Rock): boolean {
  if (g.status !== "play") return false;
  const p = position(g.player);
  return Math.abs(p.x - k.c) < 0.6 && p.y - k.r > 0.3 && p.y - k.r < 1.45;
}

/** Down through open tunnel, a cell at a time; it stops where the way below is dirt, or at the bottom. */
function fall(g: Game, k: Rock): void {
  let left = ROCK_FALL;
  while (left > 1e-9) {
    if (k.y - k.r < 1e-9 && !isOpen(g.field, k.c, k.r, 0, 1)) {
      k.y = k.r;
      crushUnder(g, k);
      land(g, k);
      return;
    }
    const d = Math.min(left, k.r + 1 - k.y);
    k.y += d;
    left -= d;
    if (k.r + 1 - k.y < 1e-9) {
      k.r++;
      k.y = k.r;
    }
    crushUnder(g, k);
  }
}

/** Whatever a falling rock comes down on is caught and carried down under it. Ghosts drift clear. */
function crushUnder(g: Game, k: Rock): void {
  for (const m of g.monsters) {
    if (m.mode !== "tunnel") continue;
    if (Math.abs(m.x - k.c) < 0.6 && m.y - k.y > -0.35 && m.y - k.y < 0.85) {
      m.mode = "crushed";
      m.move = null;
      m.fire = null;
      k.crushed.push(m.id);
      if (g.harpoon?.target === m.id) g.harpoon = null;
      g.events.push({ kind: "crush", id: m.id });
    }
  }
  for (const id of k.crushed) {
    const m = g.monsters[id];
    m.x = k.c;
    m.y = k.y + 0.32;
  }
  if (g.status === "play") {
    const p = position(g.player);
    if (Math.abs(p.x - k.c) < 0.55 && p.y - k.y > -0.35 && p.y - k.y < 0.85) {
      k.player = true;
      die(g, "rock");
    }
  }
}

function land(g: Game, k: Rock): void {
  k.phase = "crumble";
  k.t = 0;
  g.rocksDropped++;
  g.terrain++;
  const n = k.crushed.length;
  const points = CRUSH_POINTS[Math.min(n, CRUSH_POINTS.length - 1)];
  g.score += points;
  g.crushed += n;
  g.events.push({ kind: "land", rock: k.id, x: k.c, y: k.y, points, crushed: n });
  if (!g.vegShown && g.rocksDropped >= VEG_AFTER_ROCKS) showVeg(g);
}

/** The rock is dust, and what it caught is gone with it. */
function breakUp(g: Game, k: Rock): void {
  k.t = ROCK_CRUMBLE_TICKS;
  for (const id of k.crushed) g.monsters[id].mode = "dead";
}

/* ------------------------------------------------------- the vegetable */

function showVeg(g: Game): void {
  g.vegShown = true;
  g.veg = { cell: cellOf(START_COL, START_ROW), t: VEG_TICKS, index: vegIndex(g.round) };
  g.events.push({ kind: "veg", x: START_COL, y: START_ROW });
}

function updateVeg(g: Game): void {
  const v = g.veg;
  if (!v) return;
  if (--v.t <= 0) {
    g.veg = null;
    return;
  }
  const p = position(g.player);
  const x = colOf(v.cell);
  const y = rowOf(v.cell);
  if (Math.abs(p.x - x) < 0.6 && Math.abs(p.y - y) < 0.6) {
    const points = VEGGIES[v.index].points;
    g.score += points;
    g.veg = null;
    g.events.push({ kind: "bonus", x, y, points });
  }
}

/* ---------------------------------------------------------- the round */

/** The trail the monsters follow: steps through the tunnels to where the player is. */
function refreshTrail(g: Game): void {
  g.dist = tunnelSteps(g.field, playerCell(g), (cell) => rockAt(g, colOf(cell), rowOf(cell)) !== null);
}

/** Once one monster is left, and nothing is still popping or under a rock, it waits a moment and runs. */
function updateLast(g: Game): void {
  let last: Monster | null = null;
  for (const m of g.monsters) {
    if (m.mode === "dead" || m.mode === "escaped") continue;
    if (m.mode === "popping" || m.mode === "crushed" || last) return;
    last = m;
  }
  if (!last || last.mode === "flee" || last.inflate > 0 || last.fire) return;
  if (++last.fleeT >= FLEE_DELAY) startFlee(g, last);
}

/** A monster's touch or a Fygar's flame. Blown-up monsters are harmless. */
function caught(g: Game): boolean {
  const p = position(g.player);
  for (const m of g.monsters) {
    if ((m.mode !== "tunnel" && m.mode !== "ghost" && m.mode !== "flee") || m.inflate > 0) continue;
    if (Math.abs(m.x - p.x) < TOUCH && Math.abs(m.y - p.y) < TOUCH) {
      die(g, m.mode === "ghost" ? "ghost" : "monster");
      return true;
    }
    if (inFlame(m, p.x, p.y)) {
      die(g, "fire");
      return true;
    }
  }
  return false;
}

function die(g: Game, cause: DeathCause): void {
  g.status = "dying";
  g.deathT = 0;
  g.deathCause = cause;
  g.harpoon = null;
  g.pumpQueued = false;
  g.events.push({ kind: "death", cause });
}

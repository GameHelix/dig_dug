/**
 * Core Dig Dug types — pure data, no React, no DOM.
 *
 * The field is a 15 × 13 grid: row 0 is the surface, rows 1–12 the dirt, in
 * four layers of three rows. Positions are in cells with a cell's centre on
 * whole numbers, so (c, r) is the middle of column c, row r. The player and
 * the monsters in the tunnels move from centre to centre: a walker stands on
 * a cell or is on a move to a neighbour, `p` sub-steps of the way there.
 * Until a move ends the walker still counts as standing on the cell it left.
 */

export type Difficulty = "calm" | "classic" | "relentless";

export type Dir = "left" | "right" | "up" | "down";

export type MonsterKind = "pooka" | "fygar";

export interface Move {
  dc: -1 | 0 | 1;
  dr: -1 | 0 | 1;
  /** Sub-steps taken, 0 until SUB. */
  p: number;
}

export interface Walker {
  /** The cell it stands on, or leaves on its current move. */
  c: number;
  r: number;
  move: Move | null;
  /** Speed banked between ticks, in sub-steps × TICK_HZ. */
  acc: number;
  /** Sub-steps taken in all, for the walk cycle. */
  steps: number;
}

export interface Player extends Walker {
  /** Where the pump points: the way it last moved or pushed. */
  facing: Dir;
  /** The last sideways way it faced, for the sprite. */
  side: -1 | 1;
}

/**
 * What a monster is doing:
 * - `tunnel`: walking the open tunnels
 * - `ghost`: only its eyes, drifting through the dirt towards the player
 * - `flee`: the last one left, rising to the surface and running off the left edge
 * - `popping`: pumped to bursting, gone in a moment
 * - `crushed`: carried down under a falling rock
 * - `dead`, `escaped`: out of the round
 */
export type MonsterMode = "tunnel" | "ghost" | "flee" | "popping" | "crushed" | "dead" | "escaped";

/** A Fygar's breath: it glows first, then the flame comes out sideways. */
export interface Fire {
  phase: "charge" | "breath";
  /** Ticks into the phase. */
  t: number;
  dir: -1 | 1;
}

export interface Monster extends Walker {
  id: number;
  kind: MonsterKind;
  /** The cell it starts the round on, and goes back to when the player loses a life. */
  home: number;
  mode: MonsterMode;
  /** Its centre, in cells: kept in step with the walk in the tunnels, free while it drifts. */
  x: number;
  y: number;
  side: -1 | 1;
  /** The way it last walked, so a wander carries on along the tunnel. */
  heading: Dir | null;
  /** 0 when normal; each pump blows it up one size, and at INFLATE_MAX it pops. */
  inflate: number;
  /** Ticks until it shrinks a size when nobody is pumping. */
  deflateT: number;
  /** Ticks into the pop. */
  popT: number;
  /** What it is worth when it pops. */
  points: number;
  /** Ticks in the tunnels since its last ghost trip; from `ghostAt` on it may drift off. */
  ghostT: number;
  ghostAt: number;
  /** Ticks into the current ghost trip. */
  ghostFor: number;
  /** The tunnel cell a ghost is coming down into, or -1. */
  landing: number;
  fire: Fire | null;
  /** Ticks before a Fygar may breathe fire again. */
  fireT: number;
  /** Ticks it has been the last one left, before it runs. */
  fleeT: number;
}

export type RockPhase = "set" | "loose" | "fall" | "crumble";

export interface Rock {
  id: number;
  c: number;
  /** The row it rests in, or has reached while falling. */
  r: number;
  /** Its centre's row as it falls. */
  y: number;
  phase: RockPhase;
  /** Ticks into the phase. */
  t: number;
  /** Monsters it carries down. */
  crushed: number[];
  /** It caught the player. */
  player: boolean;
}

export interface Harpoon {
  dir: Dir;
  /** Where it leaves from: the player's centre when fired. */
  x: number;
  y: number;
  /** How far out the tip is, in cells. */
  len: number;
  phase: "out" | "hooked" | "back";
  /** The monster on the hook, or -1. */
  target: number;
  /** Ticks since the last pump. */
  since: number;
}

/** The bonus vegetable: it shows in the middle after two rocks have dropped. */
export interface Veg {
  cell: number;
  /** Ticks before it goes. */
  t: number;
  /** Which one, by round: an index into VEGGIES. */
  index: number;
}

export type GameStatus = "play" | "dying" | "dead" | "clear";

export type DeathCause = "monster" | "ghost" | "fire" | "rock";

/** Something worth a sound or a flash, drained by the view every frame. */
export type GameEvent =
  | { kind: "dig" }
  | { kind: "shoot" }
  | { kind: "hook"; id: number }
  | { kind: "inflate"; id: number; size: number }
  | { kind: "pop"; id: number; x: number; y: number; points: number }
  | { kind: "loose"; rock: number }
  | { kind: "crush"; id: number }
  | { kind: "land"; rock: number; x: number; y: number; points: number; crushed: number }
  | { kind: "charge"; id: number }
  | { kind: "fire"; id: number }
  | { kind: "ghost"; id: number }
  | { kind: "veg"; x: number; y: number }
  | { kind: "bonus"; x: number; y: number; points: number }
  | { kind: "hurry" }
  | { kind: "flee"; id: number }
  | { kind: "escape"; id: number }
  | { kind: "death"; cause: DeathCause }
  | { kind: "clear" };

/** What the person is asking for this tick. */
export interface Input {
  /** Held directions, the most recently pressed first. */
  dirs: readonly Dir[];
  /** The pump button is held: a hooked monster keeps blowing up. */
  pump: boolean;
}

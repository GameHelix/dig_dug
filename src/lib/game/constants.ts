import type { Difficulty } from "./types";

/** The field: 15 columns by 13 rows. Row 0 is the surface; rows 1–12 are dirt. */
export const COLS = 15;
export const ROWS = 13;
/** Four layers of dirt, three rows each; the deeper the layer, the more a pop is worth. */
export const LAYERS = 4;
export const LAYER_ROWS = 3;

/** Every life starts at the foot of the shaft in the middle of the field. */
export const START_COL = 7;
export const START_ROW = 6;

/** Sub-steps from one cell centre to the next; every move is SUB of them. */
export const SUB = 12;

/** Simulation ticks per second; the view runs a fixed-step loop at this rate. */
export const TICK_HZ = 60;

/*
 * The player's speeds, in sub-steps per second (SUB of them make a cell): a
 * little over four cells a second along a tunnel, a little over three while
 * cutting new dirt.
 */
export const PLAYER_RUN = 50;
export const PLAYER_DIG = 38;

export interface Pace {
  /** Speed along the tunnels, in sub-steps per second, on round 1. */
  walk: number;
  /** A ghost's speed, as a share of `walk`. */
  ghost: number;
  /** Ticks in the tunnels before a monster may drift off as a ghost (inclusive range). */
  ghostAfter: readonly [number, number];
  /** The most ghosts out at once. */
  ghosts: number;
  /** Ticks a Fygar waits between breaths (inclusive range). */
  fireEvery: readonly [number, number];
  /** The chance that a monster on your trail takes a turn at random instead of the shortest way. */
  stray: number;
}

/** The monsters set the difficulty: how fast they walk, how soon they ghost, how often Fygars burn. */
export const PACE: Record<Difficulty, Pace> = {
  calm: { walk: 26, ghost: 0.62, ghostAfter: [660, 960], ghosts: 1, fireEvery: [360, 600], stray: 0.35 },
  classic: { walk: 31, ghost: 0.66, ghostAfter: [480, 780], ghosts: 2, fireEvery: [240, 420], stray: 0.2 },
  relentless: { walk: 37, ghost: 0.7, ghostAfter: [330, 570], ghosts: 3, fireEvery: [170, 300], stray: 0.1 },
};

/** Each round adds this to the monsters' walk, for the first ten rounds. */
export const ROUND_WALK = 0.6;
/** Once the round's clock runs long the monsters hurry: this much faster, ghosting twice as soon. */
export const HURRY_PACE = 1.25;

/** Seconds of play before the monsters hurry: 80 on round 1, three fewer each round, never under 40. */
export function hurryAt(round: number): number {
  return TICK_HZ * Math.max(40, 80 - 3 * (round - 1));
}

/** How far the harpoon reaches, in cells, and how fast it flies out and comes back, in cells per tick. */
export const PUMP_RANGE = 3;
export const PUMP_SPEED = 0.25;
export const PUMP_BACK = 0.45;
/** The hit blows a monster up one size; at this size it pops. */
export const INFLATE_MAX = 4;
/** Holding the pump blows once every this many ticks; separate taps can come as quickly as PUMP_GAP. */
export const PUMP_REPEAT = 15;
export const PUMP_GAP = 6;
/** A blown-up monster nobody is pumping shrinks a size every this many ticks. */
export const DEFLATE_TICKS = 42;
/** Ticks from the last pump to the pop. */
export const POP_TICKS = 12;

/** Ticks a rock wobbles once the dirt under it is gone, before it drops. */
export const ROCK_LOOSE_TICKS = 40;
/** How fast a rock falls, in cells per tick. */
export const ROCK_FALL = 0.12;
/** Ticks a rock takes to break up where it lands. */
export const ROCK_CRUMBLE_TICKS = 36;

/** A ghost drifts at least this long before it may come down into a tunnel, and makes for the nearest one after the longer time. */
export const GHOST_MIN_TICKS = 50;
export const GHOST_MAX_TICKS = 600;

/** A Fygar glows for FIRE_CHARGE_TICKS, then breathes for FIRE_BREATH_TICKS; the flame grows to full length in FIRE_GROW_TICKS. */
export const FIRE_CHARGE_TICKS = 32;
export const FIRE_BREATH_TICKS = 44;
export const FIRE_GROW_TICKS = 10;
/** How far the flame reaches past the snout, in cells. It goes through dirt. */
export const FIRE_REACH = 2.4;
/** The chance, each time a rested Fygar picks a way, that it breathes fire with nobody in front of it. */
export const FIRE_WHIM = 0.07;

/** The last monster left waits this many ticks, then runs for it. */
export const FLEE_DELAY = 60;
/** On the surface it runs this much faster than it walks. */
export const FLEE_PACE = 1.15;

/**
 * A monster touches the player when their centres are closer than this, in
 * cells, along both axes.
 */
export const TOUCH = 0.7;

/** Length of the player's death, before the life starts over. */
export const DEATH_TICKS = 100;

/** The bonus vegetable shows after this many rocks have dropped, and stays this many ticks. */
export const VEG_AFTER_ROCKS = 2;
export const VEG_TICKS = 600;

/** Points: every new cell of dirt, a pop by layer (top to bottom), and a rock by the monsters it takes. */
export const DIG_POINTS = 10;
export const POP_POINTS: readonly number[] = [200, 300, 400, 500];
export const CRUSH_POINTS: readonly number[] = [0, 1000, 2500, 4000, 6000, 8000, 10000, 12000, 15000];

export interface Veggie {
  name: string;
  emoji: string;
  points: number;
}

/** The bonus by round: round 1 brings the first, round 10 and later the last. */
export const VEGGIES: readonly Veggie[] = [
  { name: "Carrot", emoji: "🥕", points: 400 },
  { name: "Mushroom", emoji: "🍄", points: 600 },
  { name: "Cucumber", emoji: "🥒", points: 800 },
  { name: "Eggplant", emoji: "🍆", points: 1000 },
  { name: "Pepper", emoji: "🫑", points: 2000 },
  { name: "Tomato", emoji: "🍅", points: 3000 },
  { name: "Garlic", emoji: "🧄", points: 4000 },
  { name: "Watermelon", emoji: "🍉", points: 5000 },
  { name: "Saucer", emoji: "🛸", points: 6000 },
  { name: "Pineapple", emoji: "🍍", points: 8000 },
];

export const vegIndex = (round: number): number => Math.min(Math.max(0, round - 1), VEGGIES.length - 1);

export const START_LIVES = 3;
export const MAX_LIVES = 9;
/** Extra lives at 10,000 points, then at 40,000 and every 40,000 after. */
export const FIRST_LIFE = 10_000;
export const LIFE_EVERY = 40_000;

/** Menu order, gentlest first. */
export const DIFFICULTIES: readonly Difficulty[] = ["calm", "classic", "relentless"];

export const DIFFICULTY_LABEL: Record<Difficulty, string> = {
  calm: "Calm",
  classic: "Classic",
  relentless: "Relentless",
};

export const DIFFICULTY_NOTE: Record<Difficulty, string> = {
  calm: "Slow monsters, one ghost at a time.",
  classic: "Monsters at the arcade pace.",
  relentless: "Quick monsters, ghosts in threes, Fygars that burn often.",
};

/** localStorage key for the menu choices and the sound switch. */
export const PREFS_KEY = "dig_dug.prefs.v1";
/** localStorage key for best scores and furthest rounds. */
export const RECORDS_KEY = "dig_dug.records.v1";

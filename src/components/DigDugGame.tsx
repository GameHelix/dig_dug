"use client";

import { useCallback, useMemo, useState } from "react";
import { MenuScreen } from "./MenuScreen";
import { PlayScreen } from "./PlayScreen";
import { ResultPanel } from "./ResultPanel";
import { RulesPanel } from "./RulesPanel";
import { cx } from "@/lib/cx";
import { PREFS_KEY, RECORDS_KEY } from "@/lib/game/constants";
import { randomSeed } from "@/lib/game/rng";
import type { Difficulty } from "@/lib/game/types";
import { useLocalStorage } from "@/lib/hooks/useLocalStorage";
import { useSound } from "@/lib/hooks/useSound";
import type { RunResult } from "@/lib/run";

export interface Prefs {
  difficulty: Difficulty;
  sound: boolean;
}

export interface Records {
  /** Best run score at each monster speed. */
  top: Record<Difficulty, number>;
  /** The furthest round reached at each monster speed. */
  round: Record<Difficulty, number>;
}

const DEFAULT_PREFS: Prefs = { difficulty: "classic", sound: true };
const EMPTY_RECORDS: Records = {
  top: { calm: 0, classic: 0, relentless: 0 },
  round: { calm: 0, classic: 0, relentless: 0 },
};

interface Session {
  difficulty: Difficulty;
  seed: number;
  /** Bumped for every run so the play screen remounts clean. */
  nonce: number;
}

/**
 * Top-level orchestrator: routes between the menu and a run, and owns the
 * persisted choices and records, the sound switch, the rules dialog and the
 * result panel. The run's seed is drawn in the Start click, so nothing random
 * runs during server rendering and the first paint matches it.
 */
export function DigDugGame() {
  const { value: prefs, store: storePrefs } = useLocalStorage<Prefs>(PREFS_KEY, DEFAULT_PREFS);
  const { value: stored, store: storeRecords } = useLocalStorage<Records>(RECORDS_KEY, EMPTY_RECORDS);
  // Records written by an older shape still read cleanly: missing fields fall back to empty.
  const records = useMemo<Records>(
    () => ({
      top: { ...EMPTY_RECORDS.top, ...stored.top },
      round: { ...EMPTY_RECORDS.round, ...stored.round },
    }),
    [stored]
  );
  const [session, setSession] = useState<Session | null>(null);
  const [rulesOpen, setRulesOpen] = useState(false);
  const [result, setResult] = useState<RunResult | null>(null);
  const play = useSound(prefs.sound);

  const begin = useCallback((difficulty: Difficulty) => {
    setResult(null);
    setSession((prev) => ({ difficulty, seed: randomSeed(), nonce: (prev?.nonce ?? 0) + 1 }));
  }, []);

  const handleStart = useCallback(() => begin(prefs.difficulty), [begin, prefs.difficulty]);
  const handleAgain = useCallback(() => {
    if (session) begin(session.difficulty);
  }, [begin, session]);

  const handleMenu = useCallback(() => {
    setResult(null);
    setSession(null);
  }, []);

  // Clearing a round reaches the next one.
  const handleCleared = useCallback(
    (round: number) => {
      if (!session) return;
      const d = session.difficulty;
      if (round + 1 > records.round[d]) storeRecords({ ...records, round: { ...records.round, [d]: round + 1 } });
    },
    [records, session, storeRecords]
  );

  const handleOver = useCallback(
    (r: RunResult) => {
      setResult(r);
      const d = r.difficulty;
      if (r.score > records.top[d] || r.round > records.round[d]) {
        storeRecords({
          top: { ...records.top, [d]: Math.max(records.top[d], r.score) },
          round: { ...records.round, [d]: Math.max(records.round[d], r.round) },
        });
      }
    },
    [records, storeRecords]
  );

  const toggleSound = useCallback(() => storePrefs({ ...prefs, sound: !prefs.sound }), [prefs, storePrefs]);

  return (
    <main className={cx("dd-app", session && "is-play")}>
      {session ? (
        <PlayScreen
          key={session.nonce}
          difficulty={session.difficulty}
          seed={session.seed}
          best={records.top[session.difficulty]}
          soundOn={prefs.sound}
          play={play}
          paused={rulesOpen || result !== null}
          onCleared={handleCleared}
          onOver={handleOver}
          onMenu={handleMenu}
          onRules={() => setRulesOpen(true)}
          onToggleSound={toggleSound}
        />
      ) : (
        <MenuScreen
          prefs={prefs}
          records={records}
          onPrefs={storePrefs}
          onStart={handleStart}
          onRules={() => setRulesOpen(true)}
        />
      )}

      {result ? (
        <ResultPanel result={result} top={records.top[result.difficulty]} onAgain={handleAgain} onMenu={handleMenu} />
      ) : null}
      {rulesOpen ? <RulesPanel onClose={() => setRulesOpen(false)} /> : null}
    </main>
  );
}

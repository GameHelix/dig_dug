"use client";

import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { FieldCanvas } from "./FieldCanvas";
import { Hud } from "./Hud";
import { TouchControls } from "./TouchControls";
import type { Difficulty, Dir } from "@/lib/game/types";
import { Run, type RunResult, type Voice } from "@/lib/run";

interface PlayScreenProps {
  difficulty: Difficulty;
  seed: number;
  /** Best score so far at this monster speed. */
  best: number;
  soundOn: boolean;
  play: (voice: Voice) => void;
  /** Freeze the round: a dialog is open over it. */
  paused: boolean;
  onCleared: (round: number) => void;
  onOver: (result: RunResult) => void;
  onMenu: () => void;
  onRules: () => void;
  onToggleSound: () => void;
}

/** Arrows and WASD by their place on the keyboard, whatever the layout. */
const KEY_DIR: Record<string, Dir> = {
  ArrowLeft: "left",
  ArrowRight: "right",
  ArrowUp: "up",
  ArrowDown: "down",
  KeyA: "left",
  KeyD: "right",
  KeyW: "up",
  KeyS: "down",
};

/** The pump: Space, or Z, X or J for a hand on the letters. */
const PUMP_KEYS = new Set(["Space", "KeyZ", "KeyX", "KeyJ"]);

/** Leave keys alone while the person is typing in a field. */
function isTyping(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  return target.closest("input, textarea, select") !== null;
}

function plural(n: number, one: string, many: string): string {
  return `${n} ${n === 1 ? one : many}`;
}

export function PlayScreen({
  difficulty,
  seed,
  best,
  soundOn,
  play,
  paused,
  onCleared,
  onOver,
  onMenu,
  onRules,
  onToggleSound,
}: PlayScreenProps) {
  // One run per mount; the parent remounts this screen for a new one.
  const [run] = useState(() => new Run(difficulty, seed));
  const view = useSyncExternalStore(run.subscribe, run.getView, run.getView);
  const [held, setHeld] = useState(false);
  const frozen = paused || held;
  const frozenRef = useRef(frozen);

  useEffect(() => {
    frozenRef.current = frozen;
    if (frozen) run.releaseAll();
  }, [frozen, run]);

  useEffect(() => {
    run.connect({ sound: play, cleared: onCleared, over: onOver });
  }, [run, play, onCleared, onOver]);

  // Leaving the tab mid-round pauses it, so nobody comes back to a lost life.
  useEffect(() => {
    const onVisibility = () => {
      if (document.hidden && (run.phase === "play" || run.phase === "dying")) setHeld(true);
    };
    document.addEventListener("visibilitychange", onVisibility);
    return () => document.removeEventListener("visibilitychange", onVisibility);
  }, [run]);

  useEffect(() => {
    const onDown = (e: KeyboardEvent) => {
      // A dialog over the field has the keys: Space and Enter press its buttons, arrows scroll it.
      if (paused || isTyping(e.target) || e.metaKey || e.ctrlKey || e.altKey) return;
      const dir = KEY_DIR[e.code];
      if (dir) {
        e.preventDefault();
        if (!frozenRef.current) run.press(dir);
        return;
      }
      if (PUMP_KEYS.has(e.code)) {
        e.preventDefault();
        if (e.repeat) return;
        if (frozenRef.current) {
          if (e.code === "Space") setHeld(false);
          return;
        }
        run.pump(true);
        return;
      }
      switch (e.code) {
        case "KeyP":
        case "Escape":
          e.preventDefault();
          setHeld((h) => !h);
          break;
        case "Enter":
          e.preventDefault();
          if (frozenRef.current) setHeld(false);
          else run.proceed();
          break;
      }
    };
    const onUp = (e: KeyboardEvent) => {
      const dir = KEY_DIR[e.code];
      if (dir) run.release(dir);
      else if (PUMP_KEYS.has(e.code)) run.pump(false);
    };
    const onBlur = () => run.releaseAll();
    window.addEventListener("keydown", onDown);
    window.addEventListener("keyup", onUp);
    window.addEventListener("blur", onBlur);
    return () => {
      window.removeEventListener("keydown", onDown);
      window.removeEventListener("keyup", onUp);
      window.removeEventListener("blur", onBlur);
    };
  }, [run, paused]);

  const over = view.phase === "over";

  return (
    <div className="dd-play">
      <div className="dd-topbar">
        <button type="button" className="dd-ghost is-small" onClick={onMenu}>
          ← Menu
        </button>
        <div className="dd-topbar-actions">
          <button
            type="button"
            className="dd-ghost is-small"
            aria-pressed={held}
            disabled={over}
            onClick={() => setHeld((h) => !h)}
          >
            {held ? "▶ Resume" : "❚❚ Pause"}
          </button>
          <button
            type="button"
            className="dd-ghost is-small"
            aria-pressed={soundOn}
            aria-label={soundOn ? "Sound on" : "Sound off"}
            onClick={onToggleSound}
          >
            {soundOn ? "🔊" : "🔇"}
          </button>
          <button type="button" className="dd-ghost is-small" aria-label="How to play" onClick={onRules}>
            ?
          </button>
        </div>
      </div>

      <Hud view={view} difficulty={difficulty} best={best} />

      <FieldCanvas run={run} paused={frozen}>
        {view.phase === "ready" && !held ? (
          <div className="dd-banner is-high">
            <span className="dd-banner-title">{`Round ${view.round}`}</span>
            <span className="dd-banner-detail">
              {`${plural(view.pookas, "Pooka", "Pookas")} · ${plural(view.total - view.pookas, "Fygar", "Fygars")} · ${plural(
                view.lives,
                "life",
                "lives"
              )}`}
            </span>
            <span className="dd-banner-detail">
              <span className="dd-only-keys">Press an arrow key to start · pump with Space</span>
              <span className="dd-only-touch">Touch the pad to start</span>
            </span>
          </div>
        ) : null}
        {view.phase === "cleared" && view.cleared ? (
          <div className="dd-banner is-good">
            <span className="dd-banner-title">Round clear!</span>
            <span className="dd-banner-detail">
              {`+${view.cleared.points.toLocaleString("en-US")} · ${view.cleared.popped} popped · ${
                view.cleared.crushed
              } under rocks`}
            </span>
            <button type="button" className="dd-primary is-small" onClick={() => run.proceed()}>
              Next round
            </button>
          </div>
        ) : null}
        {held && !over ? (
          <div className="dd-banner">
            <span className="dd-banner-title">Paused</span>
            <button type="button" className="dd-primary is-small" onClick={() => setHeld(false)} autoFocus>
              Resume
            </button>
          </div>
        ) : null}
      </FieldCanvas>

      <TouchControls run={run} />
      <p className="dd-keys">
        <kbd>←</kbd>
        <kbd>↑</kbd>
        <kbd>→</kbd>
        <kbd>↓</kbd> or <kbd>WASD</kbd> dig · <kbd>Space</kbd> pump, hold to keep pumping · <kbd>P</kbd> pause
      </p>
    </div>
  );
}

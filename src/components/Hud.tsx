"use client";

import { cx } from "@/lib/cx";
import { DIFFICULTY_LABEL } from "@/lib/game/constants";
import type { Difficulty } from "@/lib/game/types";
import type { RunView } from "@/lib/run";

interface HudProps {
  view: RunView;
  difficulty: Difficulty;
  /** Best score so far at this monster speed. */
  best: number;
}

/** Round, score, monsters left, lives and the best score, in one strip above the field. */
export function Hud({ view, difficulty, best }: HudProps) {
  return (
    <div className="dd-hud" role="status" aria-live="off">
      <div className="dd-stat is-round">
        <span className="dd-stat-label">{`Round · ${DIFFICULTY_LABEL[difficulty]}`}</span>
        <span className="dd-stat-value">{view.round}</span>
      </div>
      <div className="dd-stat">
        <span className="dd-stat-label">Score</span>
        <span className="dd-stat-value">{view.score.toLocaleString("en-US")}</span>
      </div>
      <div className={cx("dd-stat", "is-left", view.hurry && "is-hurry")}>
        <span className="dd-stat-label">{view.hurry ? "Hurry!" : "Monsters"}</span>
        <span className="dd-stat-value">{`${view.left}/${view.total}`}</span>
      </div>
      <div className="dd-stat">
        <span className="dd-stat-label">Lives</span>
        <span className="dd-stat-value" aria-label={`${view.lives} lives`}>
          {"♥".repeat(Math.min(view.lives, 9))}
        </span>
      </div>
      <div className="dd-stat is-best">
        <span className="dd-stat-label">Best</span>
        <span className="dd-stat-value">{Math.max(best, view.score).toLocaleString("en-US")}</span>
      </div>
    </div>
  );
}

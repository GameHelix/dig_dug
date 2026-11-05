"use client";

import { DIFFICULTY_LABEL } from "@/lib/game/constants";
import type { RunResult } from "@/lib/run";

interface ResultPanelProps {
  result: RunResult;
  /** Best score at this monster speed, this run included. */
  top: number;
  onAgain: () => void;
  onMenu: () => void;
}

/** End of a run: out of lives. */
export function ResultPanel({ result, top, onAgain, onMenu }: ResultPanelProps) {
  const best = result.score > 0 && result.score >= top;
  return (
    <div className="dd-overlay" role="dialog" aria-modal aria-label="Game over">
      <div className="dd-dialog">
        <h2 className="dd-dialog-title">Game over</h2>
        <p className="dd-result">{`🎈 Round ${result.round}`}</p>

        <table className="dd-score">
          <tbody>
            <tr>
              <th scope="row">Score</th>
              <td>{result.score.toLocaleString("en-US")}</td>
            </tr>
            <tr>
              <th scope="row">Rounds cleared</th>
              <td>{result.cleared}</td>
            </tr>
            <tr>
              <th scope="row">Monsters popped</th>
              <td>{result.popped}</td>
            </tr>
            <tr>
              <th scope="row">Under rocks</th>
              <td>{result.crushed}</td>
            </tr>
            <tr>
              <th scope="row">Monsters</th>
              <td>{DIFFICULTY_LABEL[result.difficulty]}</td>
            </tr>
          </tbody>
        </table>

        <p className="dd-result-note">
          {best ? <b>New best score!</b> : `Best at ${DIFFICULTY_LABEL[result.difficulty]}: ${top.toLocaleString("en-US")}`}
        </p>

        <button type="button" className="dd-primary" onClick={onAgain} autoFocus>
          Play again
        </button>
        <button type="button" className="dd-ghost" onClick={onMenu}>
          Back to menu
        </button>
      </div>
    </div>
  );
}

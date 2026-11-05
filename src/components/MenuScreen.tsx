"use client";

import type { Prefs, Records } from "./DigDugGame";
import { cx } from "@/lib/cx";
import { DIFFICULTIES, DIFFICULTY_LABEL, DIFFICULTY_NOTE } from "@/lib/game/constants";

interface MenuScreenProps {
  prefs: Prefs;
  records: Records;
  onPrefs: (prefs: Prefs) => void;
  onStart: () => void;
  onRules: () => void;
}

export function MenuScreen({ prefs, records, onPrefs, onStart, onRules }: MenuScreenProps) {
  return (
    <>
      <h1 className="dd-title">{"🎈 DIG DUG"}</h1>
      <p className="dd-subtitle">Tunnel through the dirt, pump the monsters till they pop, drop rocks on the rest.</p>

      <div className="dd-card">
        <span className="dd-field-label">Monsters</span>
        <div className="dd-choice-row">
          {DIFFICULTIES.map((d) => (
            <button
              key={d}
              type="button"
              className={cx("dd-choice", prefs.difficulty === d && "is-on")}
              aria-pressed={prefs.difficulty === d}
              onClick={() => onPrefs({ ...prefs, difficulty: d })}
            >
              {DIFFICULTY_LABEL[d]}
            </button>
          ))}
        </div>
        <p className="dd-menu-note">{DIFFICULTY_NOTE[prefs.difficulty]}</p>

        <button type="button" className="dd-primary" onClick={onStart}>
          Dig in
        </button>

        <div className="dd-record" aria-label="Best scores">
          {DIFFICULTIES.map((d) => (
            <div key={d} className={cx("dd-record-cell", prefs.difficulty === d && "is-on")}>
              <span className="dd-record-tier">{DIFFICULTY_LABEL[d]}</span>
              <span className="dd-record-score">{records.top[d].toLocaleString("en-US")}</span>
              <span className="dd-record-sub">{records.round[d] > 0 ? `best · round ${records.round[d]}` : "best score"}</span>
            </div>
          ))}
        </div>

        <div className="dd-menu-actions">
          <button type="button" className="dd-ghost" onClick={onRules}>
            How to play
          </button>
          <button
            type="button"
            className="dd-ghost"
            aria-pressed={prefs.sound}
            onClick={() => onPrefs({ ...prefs, sound: !prefs.sound })}
          >
            {prefs.sound ? "🔊 Sound on" : "🔇 Sound off"}
          </button>
        </div>
      </div>
    </>
  );
}

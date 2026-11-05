"use client";

import { useRef, useState, type PointerEvent as ReactPointerEvent } from "react";
import { cx } from "@/lib/cx";
import type { Dir } from "@/lib/game/types";
import type { Run } from "@/lib/run";

interface TouchControlsProps {
  run: Run;
}

const ARROW: Record<Dir, string> = { up: "▲", left: "◀", right: "▶", down: "▼" };
const PAD: readonly Dir[] = ["up", "left", "right", "down"];

/** Which way a point on the pad means: the axis it leans along more from the centre, with a dead zone in the middle. */
function dirAt(el: HTMLElement, x: number, y: number): Dir | null {
  const r = el.getBoundingClientRect();
  const dx = x - (r.left + r.width / 2);
  const dy = y - (r.top + r.height / 2);
  if (Math.hypot(dx, dy) < r.width * 0.12) return null;
  if (Math.abs(dx) > Math.abs(dy)) return dx < 0 ? "left" : "right";
  return dy < 0 ? "up" : "down";
}

/**
 * On-screen controls for touch screens: a pad the thumb can slide around
 * without lifting — the direction follows wherever it rests — and a pump
 * button to hold. Shown only where the pointer is coarse.
 */
export function TouchControls({ run }: TouchControlsProps) {
  const [active, setActive] = useState<Dir | null>(null);
  const [pumping, setPumping] = useState(false);
  const current = useRef<Dir | null>(null);
  const pointer = useRef<number | null>(null);

  const aim = (dir: Dir | null) => {
    if (current.current === dir) return;
    if (current.current) run.release(current.current);
    current.current = dir;
    if (dir) run.press(dir);
    setActive(dir);
  };

  const onDown = (e: ReactPointerEvent<HTMLDivElement>) => {
    e.preventDefault();
    pointer.current = e.pointerId;
    e.currentTarget.setPointerCapture(e.pointerId);
    aim(dirAt(e.currentTarget, e.clientX, e.clientY));
  };
  const onMove = (e: ReactPointerEvent<HTMLDivElement>) => {
    if (e.pointerId === pointer.current) aim(dirAt(e.currentTarget, e.clientX, e.clientY));
  };
  const onUp = (e: ReactPointerEvent<HTMLDivElement>) => {
    if (e.pointerId !== pointer.current) return;
    pointer.current = null;
    aim(null);
  };

  const pumpDown = (e: ReactPointerEvent<HTMLButtonElement>) => {
    e.preventDefault();
    e.currentTarget.setPointerCapture(e.pointerId);
    setPumping(true);
    run.pump(true);
  };
  const pumpUp = () => {
    setPumping(false);
    run.pump(false);
  };

  return (
    <div className="dd-touch">
      <div
        className="dd-pad"
        role="group"
        aria-label="Dig"
        onPointerDown={onDown}
        onPointerMove={onMove}
        onPointerUp={onUp}
        onPointerCancel={onUp}
        onLostPointerCapture={onUp}
      >
        {PAD.map((d) => (
          <span key={d} className={cx("dd-pad-arrow", `is-${d}`, active === d && "is-on")} aria-hidden>
            {ARROW[d]}
          </span>
        ))}
      </div>
      <button
        type="button"
        className={cx("dd-pump", pumping && "is-on")}
        aria-label="Pump"
        onPointerDown={pumpDown}
        onPointerUp={pumpUp}
        onPointerCancel={pumpUp}
        onLostPointerCapture={pumpUp}
      >
        <span aria-hidden>🎈</span>
        Pump
      </button>
    </div>
  );
}

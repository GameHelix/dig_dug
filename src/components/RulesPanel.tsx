"use client";

import { useEffect } from "react";

interface RulesPanelProps {
  onClose: () => void;
}

export function RulesPanel({ onClose }: RulesPanelProps) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  return (
    <div className="dd-overlay" role="dialog" aria-modal aria-label="How to play">
      <div className="dd-dialog is-wide">
        <h2 className="dd-dialog-title">How to play</h2>
        <div className="dd-rules">
          <p>
            <b>The round.</b> Get rid of every monster: pump them till they pop, or drop rocks on them. The last one
            left makes a run for the surface — catch it before it gets off the left edge, or the round ends without
            its points.
          </p>
          <p>
            <b>Digging.</b> Move anywhere you like: through dirt you dig a tunnel as you go, a little slower than you
            run along one. Every new cell of dirt is worth 10 points. You can walk the surface too.
          </p>
          <p>
            <b>The pump.</b> It fires the way you face, three cells at most, along open tunnel — never through dirt.
            Hit a monster and it blows up a size; keep pumping (hold the button, or tap) and it pops at the fourth.
            Let go and it shrinks back and comes on again. A blown-up monster is harmless to touch.
          </p>
          <p>
            <b>Rocks.</b> Dig out the dirt under a rock and it wobbles, then drops through the tunnel below — on
            whatever is there, you included. While you stand right under it, it waits. One monster under a rock is
            worth 1,000; two, 2,500; more, more. Two rocks down and a bonus vegetable shows in the middle for ten
            seconds.
          </p>
          <p>
            <b>Monsters.</b> Pookas and Fygars walk the tunnels and follow yours once they join. Left alone a while,
            they turn to ghosts — only their eyes — and drift straight through the dirt at you. Fygars stop, glow and
            breathe fire sideways, through dirt too: stay out of their row. Pops are worth more the deeper they are,
            and double for a Fygar pumped from the side. Spend too long on a round and they hurry.
          </p>
          <p>
            <b>Lives.</b> Three to start, another at 10,000 points and at every 40,000.
          </p>
          <p>
            <b>Keys.</b> Arrows or WASD to dig, Space (or Z, X, J) to pump — hold it to keep pumping — P to pause.{" "}
            <b>Touch.</b> Slide your thumb around the pad to dig, and hold the Pump button.
          </p>
        </div>
        <button type="button" className="dd-primary" onClick={onClose} autoFocus>
          Got it
        </button>
      </div>
    </div>
  );
}

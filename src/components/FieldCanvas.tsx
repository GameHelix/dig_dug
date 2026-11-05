"use client";

import { useEffect, useRef, type ReactNode } from "react";
import { FieldRenderer } from "@/lib/render/renderer";
import type { Run } from "@/lib/run";

interface FieldCanvasProps {
  run: Run;
  /** Freeze the round (paused, or a dialog is open over it). */
  paused: boolean;
  /** Overlays laid over the field: the start prompt, the round-clear banner, the pause card. */
  children?: ReactNode;
}

/**
 * The field canvas. One animation loop advances the run and repaints it;
 * while paused it keeps painting but stops the clock, and on resume the run
 * forgets the time that passed so nothing jumps.
 */
export function FieldCanvas({ run, paused, children }: FieldCanvasProps) {
  const wrapRef = useRef<HTMLDivElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const pausedRef = useRef(paused);

  useEffect(() => {
    pausedRef.current = paused;
  }, [paused]);

  useEffect(() => {
    const canvas = canvasRef.current;
    const wrap = wrapRef.current;
    if (!canvas || !wrap) return;
    const renderer = new FieldRenderer(canvas);

    const resize = () => {
      const r = wrap.getBoundingClientRect();
      renderer.resize(r.width, r.height, Math.min(window.devicePixelRatio || 1, 2.5));
    };
    resize();
    const ro = new ResizeObserver(resize);
    ro.observe(wrap);

    let raf = 0;
    let wasPaused = false;
    const loop = (t: number) => {
      if (pausedRef.current) {
        wasPaused = true;
      } else {
        if (wasPaused) run.resume();
        wasPaused = false;
        run.frame(t);
      }
      renderer.draw(run, t);
      raf = requestAnimationFrame(loop);
    };
    raf = requestAnimationFrame(loop);
    return () => {
      cancelAnimationFrame(raf);
      ro.disconnect();
    };
  }, [run]);

  return (
    <div ref={wrapRef} className="dd-board">
      <canvas ref={canvasRef} className="dd-canvas" role="img" aria-label="The field" />
      {children}
    </div>
  );
}

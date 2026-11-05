"use client";

import { useCallback, useRef } from "react";
import type { Voice } from "@/lib/run";

/**
 * Procedural Web Audio effects — no asset files, so nothing to load or 404.
 * The context is created lazily on the first sound because browsers refuse to
 * start one before a user gesture. The harpoon whips out, each pump squeaks a
 * little higher and a pop bangs; rocks rattle, thud and crumble, Fygars roar.
 * Digging is a faint scrape so the field never nags.
 */
export function useSound(enabled: boolean) {
  const ctxRef = useRef<AudioContext | null>(null);
  const noiseRef = useRef<AudioBuffer | null>(null);

  const context = useCallback((): AudioContext | null => {
    if (typeof window === "undefined") return null;
    if (!ctxRef.current) {
      const Ctor =
        window.AudioContext ||
        (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
      if (!Ctor) return null;
      ctxRef.current = new Ctor();
    }
    if (ctxRef.current.state === "suspended") void ctxRef.current.resume();
    return ctxRef.current;
  }, []);

  /** Half a second of white noise, made once and reused by every burst. */
  const noise = useCallback((ctx: AudioContext): AudioBuffer => {
    if (!noiseRef.current || noiseRef.current.sampleRate !== ctx.sampleRate) {
      const buf = ctx.createBuffer(1, Math.floor(ctx.sampleRate * 0.5), ctx.sampleRate);
      const data = buf.getChannelData(0);
      let seed = 1;
      for (let i = 0; i < data.length; i++) {
        seed = (seed * 16807) % 2147483647;
        data[i] = (seed / 2147483647) * 2 - 1;
      }
      noiseRef.current = buf;
    }
    return noiseRef.current;
  }, []);

  const tone = useCallback(
    (ctx: AudioContext, freq: number, dur: number, type: OscillatorType, gain: number, slideTo?: number, delay = 0) => {
      const t = ctx.currentTime + delay;
      const osc = ctx.createOscillator();
      const amp = ctx.createGain();
      osc.type = type;
      osc.frequency.setValueAtTime(freq, t);
      if (slideTo !== undefined) osc.frequency.exponentialRampToValueAtTime(Math.max(1, slideTo), t + dur);
      amp.gain.setValueAtTime(Math.max(0.0001, gain), t);
      amp.gain.exponentialRampToValueAtTime(0.0001, t + dur);
      osc.connect(amp).connect(ctx.destination);
      osc.start(t);
      osc.stop(t + dur + 0.02);
      // Release the nodes as soon as they are silent so nothing accumulates.
      osc.onended = () => {
        osc.disconnect();
        amp.disconnect();
      };
    },
    []
  );

  const burst = useCallback(
    (ctx: AudioContext, freq: number, q: number, dur: number, gain: number, type: BiquadFilterType = "bandpass", delay = 0) => {
      const t = ctx.currentTime + delay;
      const src = ctx.createBufferSource();
      src.buffer = noise(ctx);
      const filter = ctx.createBiquadFilter();
      filter.type = type;
      filter.frequency.value = freq;
      filter.Q.value = q;
      const amp = ctx.createGain();
      amp.gain.setValueAtTime(Math.max(0.0001, gain), t);
      amp.gain.exponentialRampToValueAtTime(0.0001, t + dur);
      src.connect(filter).connect(amp).connect(ctx.destination);
      src.start(t, Math.random() * 0.3);
      src.stop(t + dur + 0.02);
      src.onended = () => {
        src.disconnect();
        filter.disconnect();
        amp.disconnect();
      };
    },
    [noise]
  );

  const play = useCallback(
    (voice: Voice) => {
      if (!enabled) return;
      const ctx = context();
      if (!ctx) return;

      switch (voice) {
        case "dig":
          burst(ctx, 420, 0.9, 0.05, 0.025, "lowpass");
          break;
        case "shoot":
          // The harpoon whipping out: a quick rising zip.
          tone(ctx, 600, 0.08, "square", 0.025, 1500);
          burst(ctx, 3200, 2.5, 0.06, 0.03, "highpass");
          break;
        case "hook":
          tone(ctx, 520, 0.06, "square", 0.035);
          break;
        case "inflate":
          // Each pump a little higher, like a balloon filling.
          tone(ctx, 260, 0.13, "triangle", 0.08, 420);
          burst(ctx, 1800, 3, 0.07, 0.025, "bandpass", 0.03);
          break;
        case "pop":
          burst(ctx, 1400, 0.7, 0.16, 0.22);
          tone(ctx, 200, 0.14, "sine", 0.16, 55);
          break;
        case "loose":
          // A rock working loose: three dry rattles.
          [0, 0.09, 0.18].forEach((d) => burst(ctx, 380, 4, 0.05, 0.06, "bandpass", d));
          break;
        case "crush":
          tone(ctx, 300, 0.2, "square", 0.04, 80);
          break;
        case "land":
          tone(ctx, 95, 0.28, "sine", 0.2, 38);
          burst(ctx, 240, 0.7, 0.32, 0.12, "lowpass", 0.02);
          break;
        case "charge":
          tone(ctx, 140, 0.5, "sawtooth", 0.02, 230);
          break;
        case "fire":
          burst(ctx, 700, 0.6, 0.55, 0.11);
          tone(ctx, 170, 0.45, "sawtooth", 0.025, 90);
          break;
        case "ghost":
          tone(ctx, 700, 0.4, "sine", 0.025, 330);
          break;
        case "veg":
          [784, 988, 1175].forEach((f, i) => tone(ctx, f, 0.16, "triangle", 0.05, undefined, i * 0.07));
          break;
        case "bonus":
          [1046, 1318, 1568, 2093].forEach((f, i) => tone(ctx, f, 0.14, "triangle", 0.055, undefined, i * 0.05));
          break;
        case "hurry":
          [880, 698, 880, 698].forEach((f, i) => tone(ctx, f, 0.1, "square", 0.03, undefined, i * 0.12));
          break;
        case "flee":
          [523, 659, 784, 1046].forEach((f, i) => tone(ctx, f, 0.08, "square", 0.025, undefined, i * 0.06));
          break;
        case "escape":
          [784, 659, 523, 392].forEach((f, i) => tone(ctx, f, 0.14, "triangle", 0.05, undefined, i * 0.09));
          break;
        case "death":
          [494, 392, 330, 247].forEach((f, i) => tone(ctx, f, 0.22, "triangle", 0.06, f * 0.94, i * 0.11));
          break;
        case "clear":
          [523, 659, 784, 1046, 1318, 1568].forEach((f, i) => tone(ctx, f, 0.22, "triangle", 0.055, undefined, i * 0.08));
          break;
        case "life":
          [1318, 1568, 2093, 2637].forEach((f, i) => tone(ctx, f, 0.12, "triangle", 0.05, undefined, i * 0.06));
          break;
        case "start":
          tone(ctx, 660, 0.07, "triangle", 0.05);
          tone(ctx, 880, 0.09, "triangle", 0.05, undefined, 0.06);
          break;
        case "over":
          [392, 330, 262, 196, 147].forEach((f, i) => tone(ctx, f, 0.34, "triangle", 0.055, undefined, i * 0.15));
          break;
      }
    },
    [burst, context, enabled, tone]
  );

  return play;
}

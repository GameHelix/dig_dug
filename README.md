# 🎈 DIG DUG

A neon **Dig Dug**, Namco's 1982 tunnel game: dig through four layers of dirt, pump the Pookas and Fygars until they pop, and drop rocks on whatever is underneath. Built with **Next.js 16**, **TypeScript** (strict) and **Tailwind CSS v4**, on a fixed-step engine that cuts the tunnels sub-step by sub-step: tunnels side by side keep a skin of dirt between them, a cut you turn back from stays half-dug, and the monsters walk only what is really open — until they give up and drift through the dirt as a pair of eyes.

## ✨ Features

| | |
| --- | --- |
| ⛏️ Real digging | Tunnels are cut as you move, a little slower than you run along them; turn back halfway and the half-dug stub stays |
| 🎈 Pump to pop | The harpoon flies three cells along open tunnel, never through dirt; each pump blows a monster up a size and the fourth pops it — let go and it shrinks back |
| 🪨 Rocks | Dig out the dirt under one and it wobbles, then drops through the tunnel below, taking every monster in its way: 1,000 for one, 2,500 for two, up to 15,000 |
| 👀 Ghosts | Monsters left alone drift off as eyes, straight through the dirt at you, and come down into the first tunnel they cross |
| 🔥 Fygars | They stop, glow and breathe fire sideways — through dirt too |
| 🏃 The last one runs | The last monster left heads for the surface and the left edge; catch it, or the round ends without its points |
| 🥕 Bonus vegetables | Two rocks down and one shows in the middle for ten seconds — a carrot on round 1, up to a pineapple worth 8,000 from round 10 |
| 🗺️ Endless rounds | Each round has its own fixed layout, with more monsters, more Fygars and more rocks as you go, up to eight monsters; a flower on the surface counts the rounds |
| 🎚️ Three monster speeds | Calm, Classic and Relentless set how fast they walk, how soon and how many turn to ghosts, and how often Fygars burn |
| ⏰ Hurry | Spend too long on a round and the monsters speed up and ghost twice as soon |
| 📱 Keys and touch | Arrows or WASD and Space on a keyboard; a thumb pad and a Pump button on a phone |
| 🏆 Records | Best score and furthest round per monster speed, saved locally |
| 🔊 Procedural audio | Web Audio zips, squeaks, pops, rattles and roars — no asset files |
| 🌗 Polished | Glowing neon layers and animated figures, reduced-motion aware, pauses itself when the tab is hidden |

## 🎮 How to play

1. Pick a monster speed and dig in. Each round starts with you at the foot of the shaft in the middle and the monsters sealed in their own tunnels.
2. Move to dig: every new cell of dirt is worth 10 points.
3. Face a monster along an open tunnel and pump until it pops; while it is blown up it can't hurt you. A pop is worth 200 in the top layer up to 500 at the bottom, and double for a Fygar pumped from the side.
4. Dig out the dirt under rocks to drop them on monsters — not on yourself. A rock waits while you stand right under it.
5. Stay out of a Fygar's row when it glows, and watch for eyes drifting through the dirt.
6. Get rid of every monster to clear the round. Three lives to start, another at 10,000 points and at every 40,000.

**Keys:** arrows / `WASD` dig · `Space` (or `Z`, `X`, `J`) pump, hold to keep pumping · `P` / `Esc` pause · `Enter` start or go on to the next round. **Touch:** slide your thumb around the pad and hold **Pump**.

## 🛠 Tech

- **Next.js 16** (App Router) + **React 19**
- **TypeScript 5**, strict mode
- **Tailwind CSS v4** via `@tailwindcss/postcss`
- **Vitest 3** for the core-logic unit tests
- Pure, framework-free game engine (tunnel field with half-dug ways, fixed-tick engine, harpoon and pump, rocks, monster path-finding, ghosts and fire, round layouts) under `src/lib/game`

## Getting started

```bash
npm install
npm run dev      # http://localhost:3000
```

```bash
npm run build    # production build
npm test         # run the unit tests
npm run lint     # lint the project
```

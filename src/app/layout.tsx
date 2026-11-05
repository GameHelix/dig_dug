import type { Metadata, Viewport } from "next";
import "./globals.css";

/** A Pooka in its goggles, inline, so the tab has an icon without any asset file. */
const ICON =
  "data:image/svg+xml," +
  encodeURIComponent(
    "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'>" +
      "<defs><radialGradient id='p' cx='0.36' cy='0.32' r='0.75'><stop offset='0' stop-color='#ffe4e6'/>" +
      "<stop offset='0.4' stop-color='#fb7185'/><stop offset='1' stop-color='#be123c'/></radialGradient></defs>" +
      "<rect x='3' y='3' width='58' height='58' rx='14' fill='#070610' stroke='#22d3ee' stroke-width='3'/>" +
      "<circle cx='32' cy='35' r='17' fill='url(#p)'/>" +
      "<rect x='26' y='24' width='24' height='12' rx='6' fill='#facc15'/>" +
      "<circle cx='33' cy='30' r='3.8' fill='#fff'/><circle cx='43' cy='30' r='3.8' fill='#fff'/>" +
      "<circle cx='34' cy='30' r='1.8' fill='#0f172a'/><circle cx='44' cy='30' r='1.8' fill='#0f172a'/>" +
      "</svg>"
  );

export const metadata: Metadata = {
  title: "Dig Dug — a neon tunnel arcade",
  icons: { icon: ICON },
  description:
    "Neon Dig Dug built with Next.js and TypeScript. Tunnel through four layers of dirt, pump Pookas and Fygars until they pop and drop rocks on them, with ghosts, fire-breathing Fygars, bonus vegetables, three monster speeds, keyboard and touch controls.",
};

export const viewport: Viewport = {
  themeColor: "#070610",
  width: "device-width",
  initialScale: 1,
  viewportFit: "cover",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}

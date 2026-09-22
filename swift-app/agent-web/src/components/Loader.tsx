import React from "react";

/// beautifului #01 loading state, ported verbatim from
/// beautifului.dev/r/loading-state.json + foundation.css:
/// a 3×3 pixel grid whose cells pulse in a chevron wavefront —
/// (col + |row-1|) * 90ms stagger over a 650ms cycle, opacity-only
/// (0.15 → 1 → 0.15), no scale. `size` scales the cells; 15px is
/// the canonical 4px-cell grid.
const chevron: number[] = Array.from({ length: 9 }, (_, i) => {
  const r = Math.floor(i / 3), c = i % 3;
  return (c + Math.abs(r - 1)) * 90;
});

export function LoaderGrid({ size = 15 }: { size?: number }) {
  const cell = Math.max(2, size * 4 / 15);
  return (
    <span className="loader-grid" aria-hidden
      style={{ width: size, height: size }}>
      {chevron.map((delay, i) => (
        <i key={i}
          style={{
            width: cell, height: cell,
            opacity: 0.15,
            animation: `pixel-on 650ms ease-in-out ${delay}ms infinite`,
          }} />
      ))}
    </span>
  );
}

export function fmtElapsed(ms: number): string {
  const s = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  if (h > 0) return `${h}:${String(m).padStart(2, "0")}:${String(sec).padStart(2, "0")}`;
  return `${m}:${String(sec).padStart(2, "0")}`;
}

/// 01's live elapsed: tenths while under a minute ("12.3s"), then
/// "1m 23.4s". The ticking tenth is the alive-ness cue.
export function fmtElapsedTenths(ms: number): string {
  const t = Math.max(0, ms);
  const total = Math.floor(t / 100) / 10;
  if (total < 60) return `${total.toFixed(1)}s`;
  return `${Math.floor(total / 60)}m ${(total % 60).toFixed(1)}s`;
}

import React from "react";

/// beautifului #01 loading state: a 3×3 pixel grid pulsing in a
/// diagonal stagger. Replaces the single spinner on every live phase
/// chip (thinking / executing / compacting) and doubles as the plan
/// row's in-progress mark.
export function LoaderGrid({ size = 12 }: { size?: number }) {
  return (
    <span className="loader-grid" aria-hidden
      style={{ width: size, height: size }}>
      {Array.from({ length: 9 }, (_, i) => (
        <i key={i}
          style={{ animationDelay: `${((i % 3) + Math.floor(i / 3)) * 110}ms` }} />
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

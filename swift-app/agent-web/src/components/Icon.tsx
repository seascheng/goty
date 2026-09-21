import React from "react";

/// Minimal 24px stroke icons (lucide-style geometry, no dependency).
export function Icon({ kind }: { kind: "history" | "model" | "mode" | "thinking" | "speed"
  | "stop" | "send" | "folder" | "branch" | "copy" | "check" | "messages" }) {
  const common = { width: 13, height: 13, viewBox: "0 0 24 24", fill: "none",
                   stroke: "currentColor", strokeWidth: 2,
                   strokeLinecap: "round" as const, strokeLinejoin: "round" as const };
  switch (kind) {
    case "history":
      return <svg {...common}><circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" /><path d="M3 12a9 9 0 1 0 3-6.7L3 8" /><path d="M3 3v5h5" /></svg>;
    case "model":
      return <svg {...common}><path d="M13 2 4 14h6l-1 8 9-12h-6l1-8z" /></svg>;
    case "mode":
      return <svg {...common}><circle cx="12" cy="12" r="9" /><path d="M15.5 8.5 10 10l-1.5 5.5L14 13.5z" /></svg>;
    case "speed":
      return <svg {...common}><path d="M3.34 19a10 10 0 1 1 17.32 0" /><path d="m12 14 4-6" /><path d="m12 14-4-6" /></svg>;
    case "thinking":
      return <svg {...common}><path d="M3 12h4l3-8 4 16 3-8h4" /></svg>;
    case "stop":
      return <svg {...common}><rect x="6" y="6" width="12" height="12" rx="2" fill="currentColor" stroke="none" /></svg>;
    case "send":
      return <svg {...common}><path d="M12 19V5" /><path d="M5 12l7-7 7 7" /></svg>;
    case "folder":
      return <svg {...common}><path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z" /></svg>;
    case "branch":
      return <svg {...common}><line x1="6" x2="6" y1="3" y2="15" /><circle cx="18" cy="6" r="3" /><circle cx="6" cy="18" r="3" /><path d="M18 9a9 9 0 0 1-9 9" /></svg>;
    case "copy":
      return <svg {...common}><rect x="9" y="9" width="13" height="13" rx="2" /><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" /></svg>;
    case "check":
      return <svg {...common}><path d="M20 6 9 17l-5-5" /></svg>;
    case "messages":
      return <svg {...common}><line x1="8" y1="6" x2="21" y2="6" /><line x1="8" y1="12" x2="21" y2="12" /><line x1="8" y1="18" x2="21" y2="18" /><line x1="3" y1="6" x2="3.01" y2="6" /><line x1="3" y1="12" x2="3.01" y2="12" /><line x1="3" y1="18" x2="3.01" y2="18" /></svg>;
  }
}

/// Fold indicator for tool/thought cards; `.up` rotates it open.
export function Chevron({ open }: { open?: boolean }) {
  return (
    <span className={"chevron" + (open ? " up" : "")} aria-hidden>
      <svg width={12} height={12} viewBox="0 0 24 24" fill="none"
        stroke="currentColor" strokeWidth={2.4}
        strokeLinecap="round" strokeLinejoin="round"><path d="m9 18 6-6-6-6" /></svg>
    </span>
  );

}

import { Icon } from "./Icon";
import React, { useEffect, useMemo, useRef, useState } from "react";
import { Popover, type PopoverAnchor } from "../ui/Popover";
import { type ConfigChoice } from "../store";

/// Big catalogs (models) get a search row; short knobs do not.
const CONFIG_SEARCH_THRESHOLD = 8;

/// Popover body for a config knob: search row (long catalogs) +
/// monocode-ModelPicker-style rows with keyboard navigation. Mounted only
/// while open, so search/keyboard state resets on every open.
/// (beautifului #08 prompt-bar surface: card chrome lives in CSS.)
export function ConfigPopover({ anchor, option, onDismiss, onPick }: {
  anchor: PopoverAnchor;
  option: { id: string; name: string; currentValue?: string | null;
            options: ConfigChoice[] };
  onDismiss: () => void; onPick: (value: string) => void;
}) {
  const [query, setQuery] = useState("");
  const [active, setActive] = useState(0);
  const search = useRef<HTMLInputElement>(null);
  const activeRow = useRef<HTMLDivElement>(null);
  const searchable = option.options.length > CONFIG_SEARCH_THRESHOLD;
  const needle = query.trim().toLowerCase();
  const visible = useMemo(() => needle
    ? option.options.filter((o) => `${o.name} ${o.value}`.toLowerCase().includes(needle))
    : option.options,
    [option.options, needle]);

  useEffect(() => {
    const i = visible.findIndex((o) => o.value === option.currentValue);
    setActive(i >= 0 ? i : 0);
  }, [visible, option.currentValue]);

  useEffect(() => {
    if (!searchable) return;
    search.current?.focus({ preventScroll: true });
    // First paint can be pre-placement (visibility hidden) — WebKit
    // silently drops focus() there. Retry once post-paint.
    const raf = requestAnimationFrame(() => search.current?.focus({ preventScroll: true }));
    return () => cancelAnimationFrame(raf);
  }, [searchable]);

  useEffect(() => {
    activeRow.current?.scrollIntoView({ block: "nearest" });
  }, [active]);

  const onKey = (e: React.KeyboardEvent) => {
    if (e.nativeEvent.isComposing) return;
    if (e.key === "ArrowDown") {
      e.preventDefault();
      setActive((i) => Math.min(visible.length - 1, i + 1));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setActive((i) => Math.max(0, i - 1));
    } else if (e.key === "Enter") {
      e.preventDefault();
      const item = visible[active];
      if (item) onPick(item.value);
    }
  };

  return (
    <Popover anchor={anchor} side="top"
      width={searchable ? 300 : 220}
      minHeight={120} maxHeight={340}
      onDismiss={onDismiss} role="dialog" aria-label={option.name}
      className="flex flex-col overflow-hidden"
      // No search row → the surface itself takes the arrow keys.
      autoFocus={!searchable} tabIndex={searchable ? undefined : -1}
      onKeyDown={searchable ? undefined : onKey}>
      {searchable && (
        <label className="flex items-center gap-2 border-b border-content/10 px-2 py-2.5 text-content/50">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none"
            stroke="currentColor" strokeWidth="2" strokeLinecap="round"
            strokeLinejoin="round" aria-hidden>
            <circle cx="11" cy="11" r="7" />
            <line x1="21" x2="16.5" y1="21" y2="16.5" />
          </svg>
          <input ref={search} value={query} placeholder="搜索…"
            aria-label={`搜索${option.name}`}
            className="min-w-0 flex-1 bg-transparent text-[12px] text-content outline-none placeholder:text-content/40"
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={onKey} />
        </label>
      )}
      <div role="listbox" aria-label={option.name}
        className="min-h-0 flex-1 overflow-y-auto overscroll-none px-1.5 pb-1.5">
        {visible.length === 0 && (
          <div className="px-3 py-4 text-[12px] text-content/50">无匹配选项</div>
        )}
        {visible.map((o, index) => {
          const selected = o.value === option.currentValue;
          const highlighted = index === active;
          return (
            <div key={o.value} ref={highlighted ? activeRow : undefined}
              onMouseEnter={() => setActive(index)}
              className={"pop-row"
                + (selected ? " cur" : "")
                + (highlighted ? " hot" : "")}>
              <button role="option" aria-selected={selected}
                onMouseDown={(e) => e.preventDefault()}
                onClick={() => onPick(o.value)}
                className="flex min-w-0 flex-1 items-center gap-2 px-1.5 py-1.5 text-left text-content">
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-[12.5px] font-medium leading-5">{o.name}</span>
                  {o.source && (
                    <span className="block truncate text-[11px] leading-[13.5px] text-content/50">{o.source}</span>
                  )}
                </span>
                {/* 08 picker: the check column is ALWAYS present
                    (invisible when not selected) so rows don't shift,
                    and it carries selection — no fill, ink color. */}
                <span className={"pop-check" + (selected ? "" : " invisible")} aria-hidden>
                  <Icon kind="check" />
                </span>
              </button>
            </div>
          );
        })}
      </div>
    </Popover>
  );
}


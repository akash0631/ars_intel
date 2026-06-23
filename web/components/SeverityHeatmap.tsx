'use client';

import type { AlertRow } from '@/lib/api';
import { SEVERITY_WEIGHT, heatmapShade } from '@/lib/severity';
import { cn } from '@/lib/utils';

interface SeverityHeatmapProps {
  alerts: AlertRow[];
  onCellClick?: (store: string, majcat: string) => void;
}

interface Cell {
  store: string;
  majcat: string;
  score: number;
  count: number;
}

export function SeverityHeatmap({ alerts, onCellClick }: SeverityHeatmapProps) {
  const stores = Array.from(new Set(alerts.map((a) => a.store))).sort();
  const majcats = Array.from(new Set(alerts.map((a) => a.majcat))).sort();

  const grid: Record<string, Cell> = {};
  for (const a of alerts) {
    const key = `${a.majcat}|${a.store}`;
    if (!grid[key]) grid[key] = { store: a.store, majcat: a.majcat, score: 0, count: 0 };
    grid[key].score += SEVERITY_WEIGHT[a.severity] ?? 0;
    grid[key].count += 1;
  }

  if (stores.length === 0 || majcats.length === 0) {
    return (
      <div className="rounded-lg border border-dashed border-border p-8 text-center text-sm text-muted-foreground">
        No alerts to display
      </div>
    );
  }

  return (
    <div className="overflow-auto rounded-lg border border-border bg-card">
      <div className="inline-block min-w-full p-2">
        <div
          className="grid gap-1"
          style={{
            gridTemplateColumns: `minmax(140px, max-content) repeat(${stores.length}, minmax(48px, 1fr))`,
          }}
        >
          <div />
          {stores.map((s) => (
            <div
              key={s}
              className="px-1 py-1 text-center text-[10px] font-medium text-muted-foreground"
              title={s}
            >
              {s}
            </div>
          ))}
          {majcats.map((m) => (
            <div key={m} className="contents">
              <div className="flex items-center px-2 py-1 text-xs font-medium text-muted-foreground">
                {m}
              </div>
              {stores.map((s) => {
                const cell = grid[`${m}|${s}`];
                const score = cell?.score ?? 0;
                return (
                  <button
                    key={`${m}|${s}`}
                    type="button"
                    onClick={() => onCellClick?.(s, m)}
                    title={`${m} · ${s}\nScore ${score} · ${cell?.count ?? 0} alerts`}
                    className={cn(
                      'aspect-square min-h-[28px] rounded-sm border border-border/30 transition hover:ring-2 hover:ring-ring',
                      heatmapShade(score),
                    )}
                  >
                    <span className="sr-only">
                      {m} {s} score {score}
                    </span>
                  </button>
                );
              })}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

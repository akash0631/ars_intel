'use client';

import { useMemo, useState } from 'react';
import useSWR from 'swr';
import { AlertTriangle, X } from 'lucide-react';
import { AlertCard } from '@/components/AlertCard';
import { api, type AlertRow } from '@/lib/api';
import { SEVERITY_BG, SEVERITY_LABEL, ruleLabel, type Severity } from '@/lib/severity';
import { cn } from '@/lib/utils';

const DEFAULT_LIMIT = 20;
const SEV_FILTERS: (Severity | 'all')[] = ['all', 'crit', 'high', 'med', 'low'];

export default function TodayPage() {
  const [limit] = useState(DEFAULT_LIMIT);
  const [ruleFilter, setRuleFilter] = useState<string | null>(null);
  const [sevFilter, setSevFilter] = useState<Severity | 'all'>('all');
  const [active, setActive] = useState<AlertRow | null>(null);

  const { data, error, isLoading } = useSWR<AlertRow[]>(
    ['alerts-top', limit],
    () => api.alertsTop({ limit }),
    { revalidateOnFocus: false },
  );

  const rules = useMemo(() => {
    if (!data) return [] as string[];
    const set = new Set<string>();
    for (const a of data) set.add(a.rule_id);
    return Array.from(set).sort();
  }, [data]);

  const filtered = useMemo(() => {
    if (!data) return [] as AlertRow[];
    return data.filter(
      (a) =>
        (!ruleFilter || a.rule_id === ruleFilter) &&
        (sevFilter === 'all' || a.severity === sevFilter),
    );
  }, [data, ruleFilter, sevFilter]);

  const totalLost = useMemo(
    () => filtered.reduce((s, a) => s + (Number(a.lost_qty) || 0), 0),
    [filtered],
  );

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight">Today</h2>
          <p className="text-sm text-muted-foreground">
            Top {limit} alerts ranked by severity and lost demand.
          </p>
        </div>
        <div className="rounded-lg border border-border bg-card px-4 py-3">
          <div className="text-xs uppercase tracking-wide text-muted-foreground">
            Total lost qty
          </div>
          <div className="mt-1 text-2xl font-semibold tabular-nums">
            {totalLost.toLocaleString()}
          </div>
        </div>
      </div>

      <div className="flex flex-col gap-3">
        <div className="flex flex-wrap items-center gap-2">
          {SEV_FILTERS.map((s) => {
            const selected = sevFilter === s;
            return (
              <button
                key={s}
                type="button"
                onClick={() => setSevFilter(s)}
                className={cn(
                  'rounded-full border px-3 py-1 text-xs font-medium transition-colors',
                  selected
                    ? s === 'all'
                      ? 'border-foreground bg-foreground text-background'
                      : SEVERITY_BG[s as Severity]
                    : 'border-border text-muted-foreground hover:text-foreground',
                )}
              >
                {s === 'all' ? 'All severities' : SEVERITY_LABEL[s as Severity]}
              </button>
            );
          })}
        </div>
        {rules.length > 0 && (
          <div className="flex flex-wrap items-center gap-2">
            <button
              type="button"
              onClick={() => setRuleFilter(null)}
              className={cn(
                'rounded-full border px-3 py-1 text-xs font-medium transition-colors',
                !ruleFilter
                  ? 'border-foreground bg-foreground text-background'
                  : 'border-border text-muted-foreground hover:text-foreground',
              )}
            >
              All rules
            </button>
            {rules.map((r) => (
              <button
                key={r}
                type="button"
                onClick={() => setRuleFilter(r === ruleFilter ? null : r)}
                className={cn(
                  'rounded-full border px-3 py-1 text-xs font-medium transition-colors',
                  ruleFilter === r
                    ? 'border-foreground bg-foreground text-background'
                    : 'border-border text-muted-foreground hover:text-foreground',
                )}
              >
                {r} · {ruleLabel(r)}
              </button>
            ))}
          </div>
        )}
      </div>

      {error && (
        <div className="flex items-center gap-3 rounded-lg border border-severity-crit/40 bg-severity-crit/10 px-4 py-3 text-sm">
          <AlertTriangle className="h-4 w-4 text-severity-crit" />
          <span>Failed to load alerts. Check the API and try again.</span>
        </div>
      )}

      {isLoading && (
        <div className="space-y-3">
          {Array.from({ length: 6 }).map((_, i) => (
            <div
              key={i}
              className="h-16 animate-pulse rounded-lg border border-border bg-card/60"
            />
          ))}
        </div>
      )}

      {!isLoading && !error && filtered.length === 0 && (
        <div className="rounded-lg border border-dashed border-border bg-card/40 px-6 py-12 text-center">
          <div className="text-base font-medium">No alerts match these filters</div>
          <div className="mt-1 text-sm text-muted-foreground">
            Try clearing the rule or severity filter, or wait for the next run.
          </div>
        </div>
      )}

      {!isLoading && !error && filtered.length > 0 && (
        <div className="space-y-3">
          {filtered.map((a) => (
            <AlertCard key={a.alert_id} alert={a} onFix={setActive} />
          ))}
        </div>
      )}

      {active && <DetailModal alert={active} onClose={() => setActive(null)} />}
    </div>
  );
}

function DetailModal({ alert, onClose }: { alert: AlertRow; onClose: () => void }) {
  return (
    <div
      className="fixed inset-0 z-50 flex items-end justify-center bg-black/60 p-0 sm:items-center sm:p-4"
      onClick={onClose}
    >
      <div
        role="dialog"
        aria-modal="true"
        onClick={(e) => e.stopPropagation()}
        className="flex max-h-[90vh] w-full max-w-2xl flex-col rounded-t-xl border border-border bg-card text-card-foreground shadow-xl sm:rounded-xl"
      >
        <div className="flex items-start justify-between gap-3 border-b border-border px-5 py-4">
          <div className="min-w-0">
            <div className="text-xs uppercase tracking-wide text-muted-foreground">
              Fix action
            </div>
            <div className="mt-1 truncate text-base font-medium">{alert.fix_action}</div>
            <div className="mt-1 flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
              <span>{alert.store}</span>
              <span>·</span>
              <span>{alert.majcat}</span>
              <span>·</span>
              <span>{ruleLabel(alert.rule_id)}</span>
              <span
                className={cn(
                  'rounded-md border px-2 py-0.5 font-medium',
                  SEVERITY_BG[alert.severity],
                )}
              >
                {SEVERITY_LABEL[alert.severity]}
              </span>
            </div>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="rounded-md p-1 text-muted-foreground hover:bg-muted hover:text-foreground"
            aria-label="Close"
          >
            <X className="h-4 w-4" />
          </button>
        </div>
        <div className="flex-1 overflow-auto px-5 py-4">
          <div className="mb-3 grid grid-cols-2 gap-3 text-sm">
            <div>
              <div className="text-xs uppercase tracking-wide text-muted-foreground">
                Lost qty
              </div>
              <div className="mt-1 text-lg font-semibold tabular-nums">
                {Number(alert.lost_qty).toLocaleString()}
              </div>
            </div>
            <div>
              <div className="text-xs uppercase tracking-wide text-muted-foreground">
                Run date
              </div>
              <div className="mt-1 text-lg font-semibold tabular-nums">
                {alert.run_date}
              </div>
            </div>
          </div>
          <div className="mb-3">
            <div className="text-xs uppercase tracking-wide text-muted-foreground">
              Root cause
            </div>
            <div className="mt-1 text-sm">{alert.root_cause}</div>
          </div>
          <div>
            <div className="mb-1 text-xs uppercase tracking-wide text-muted-foreground">
              Detail JSON
            </div>
            <pre className="max-h-96 overflow-auto rounded-md border border-border bg-background p-3 text-xs leading-relaxed">
              {JSON.stringify(alert.details ?? {}, null, 2)}
            </pre>
          </div>
        </div>
      </div>
    </div>
  );
}

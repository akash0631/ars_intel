'use client';

import { useMemo, useState } from 'react';
import useSWR from 'swr';
import {
  ChevronRight,
  Layers,
  Database,
  AlertTriangle,
  Loader2,
} from 'lucide-react';
import {
  api,
  fetcher,
  qs,
  type DrillBreakdown,
  type DrillLeaf,
  type DrillLevel,
  type DrillNode,
  type SessionRow,
} from '@/lib/api';
import { cn } from '@/lib/utils';

type Crumb = {
  level: DrillLevel;
  key: string;
  label: string;
};

const LEVEL_LABEL: Record<DrillLevel, string> = {
  session: 'Session',
  majcat: 'MajCat',
  grid: 'Grid attr',
  combo: 'Attribute combo',
  size: 'Size',
  store_article: 'Store-Article',
};

const LEVEL_ORDER: DrillLevel[] = [
  'session',
  'majcat',
  'grid',
  'combo',
  'size',
  'store_article',
];

const nextLevel = (l: DrillLevel): DrillLevel | null => {
  const i = LEVEL_ORDER.indexOf(l);
  return i >= 0 && i < LEVEL_ORDER.length - 1 ? LEVEL_ORDER[i + 1] : null;
};

const fmt = (n: number | undefined | null) =>
  n == null || Number.isNaN(n)
    ? '—'
    : Math.round(n).toLocaleString('en-IN');

const gapPct = (req: number, alloc: number) => {
  if (!req || req <= 0) return 0;
  return Math.max(0, Math.min(100, ((req - alloc) / req) * 100));
};

const buildBreakdownParams = (crumbs: Crumb[]) => {
  const sessionCrumb = crumbs[0];
  if (!sessionCrumb) return null;
  const last = crumbs[crumbs.length - 1];
  const target = nextLevel(last.level);
  if (!target) return null;
  const params: Record<string, string> = {
    session_id: sessionCrumb.key,
    level: target,
  };
  for (const c of crumbs) {
    if (c.level === 'majcat') params.majcat = c.key;
    if (c.level === 'grid') params.grid_attr = c.key;
    if (c.level === 'combo') params.combo = c.key;
    if (c.level === 'size') params.size = c.key;
    if (c.level === 'store_article') {
      const [store, article] = c.key.split('|');
      if (store) params.store = store;
      if (article) params.combo = article;
    }
  }
  return params;
};

export default function DrillPage() {
  const [sessionId, setSessionId] = useState<string>('');
  const [crumbs, setCrumbs] = useState<Crumb[]>([]);
  const [leafKey, setLeafKey] = useState<{ store: string; article: string } | null>(
    null,
  );

  const { data: sessions, isLoading: loadingSessions } = useSWR<SessionRow[]>(
    '/api/drill/sessions',
    () => api.drillSessions({}),
  );

  const uniqueSessions = useMemo(() => {
    if (!sessions) return [];
    const seen = new Set<string>();
    const out: SessionRow[] = [];
    for (const s of sessions) {
      if (seen.has(s.session_id)) continue;
      seen.add(s.session_id);
      out.push(s);
    }
    return out;
  }, [sessions]);

  const breakdownParams = useMemo(() => buildBreakdownParams(crumbs), [crumbs]);
  const breakdownKey = breakdownParams
    ? `/api/drill/breakdown${qs(breakdownParams)}`
    : null;

  const { data: breakdown, isLoading: loadingBreakdown, error: breakdownError } =
    useSWR<DrillBreakdown>(breakdownKey, fetcher);

  const leafQs = leafKey && sessionId
    ? qs({ session_id: sessionId, store: leafKey.store, article: leafKey.article })
    : null;
  const { data: leaf, isLoading: loadingLeaf } = useSWR<DrillLeaf>(
    leafQs ? `/api/drill/leaf${leafQs}` : null,
    fetcher,
  );

  const pickSession = (s: SessionRow) => {
    setSessionId(s.session_id);
    setCrumbs([
      { level: 'session', key: s.session_id, label: s.session_id },
    ]);
    setLeafKey(null);
  };

  const drillInto = (node: DrillNode) => {
    setCrumbs((prev) => [
      ...prev,
      { level: node.level, key: node.key, label: node.label },
    ]);
    if (node.level === 'store_article') {
      const [store, article] = node.key.split('|');
      setLeafKey({ store: store ?? '', article: article ?? '' });
    } else {
      setLeafKey(null);
    }
  };

  const jumpToCrumb = (idx: number) => {
    setCrumbs((prev) => prev.slice(0, idx + 1));
    setLeafKey(null);
  };

  const currentLevel: DrillLevel = crumbs[crumbs.length - 1]?.level ?? 'session';
  const targetLevel = nextLevel(currentLevel);

  return (
    <div className="flex flex-col gap-6">
      <div>
        <div className="flex items-center gap-2 text-sm text-muted-foreground">
          <Layers className="h-4 w-4" />
          Drill
        </div>
        <h2 className="mt-1 text-2xl font-semibold tracking-tight">
          6-level allocation cascade
        </h2>
        <p className="text-sm text-muted-foreground">
          Session &gt; MajCat &gt; Grid attr &gt; Attribute combo &gt; Size &gt;
          Store-Article. Req vs Allocated vs Gap at every step.
        </p>
      </div>

      {!sessionId && (
        <SessionPicker
          loading={loadingSessions}
          sessions={uniqueSessions}
          onPick={pickSession}
        />
      )}

      {sessionId && (
        <>
          <Breadcrumbs crumbs={crumbs} onJump={jumpToCrumb} />
          <BreakdownPanel
            level={targetLevel}
            data={breakdown}
            loading={loadingBreakdown}
            error={breakdownError as Error | undefined}
            onDrill={drillInto}
          />
          <LeafPanel leaf={leaf} loading={loadingLeaf} active={!!leafKey} />
        </>
      )}
    </div>
  );
}

function SessionPicker({
  loading,
  sessions,
  onPick,
}: {
  loading: boolean;
  sessions: SessionRow[];
  onPick: (s: SessionRow) => void;
}) {
  if (loading) {
    return (
      <div className="space-y-2">
        {Array.from({ length: 5 }).map((_, i) => (
          <div
            key={i}
            className="h-12 animate-pulse rounded-lg border border-border bg-card"
          />
        ))}
      </div>
    );
  }
  if (!sessions.length) {
    return (
      <EmptyState
        title="No sessions"
        body="No ARS listing sessions found for the selected run date."
      />
    );
  }
  return (
    <div className="rounded-lg border border-border bg-card">
      <div className="border-b border-border px-4 py-3 text-sm font-medium">
        Pick a session
      </div>
      <ul className="divide-y divide-border">
        {sessions.map((s) => (
          <li key={s.session_id}>
            <button
              type="button"
              onClick={() => onPick(s)}
              className="flex w-full items-center justify-between gap-3 px-4 py-3 text-left hover:bg-secondary/50"
            >
              <div className="min-w-0">
                <div className="truncate font-medium">{s.session_id}</div>
                <div className="text-xs text-muted-foreground">
                  {s.run_date} · {s.store || '—'} · {s.majcat || 'all majcats'}
                </div>
              </div>
              <div className="flex shrink-0 items-center gap-3">
                <span
                  className={cn(
                    'rounded-md border px-2 py-0.5 text-xs',
                    s.status === 'SUCCESS'
                      ? 'border-emerald-700/40 bg-emerald-950/40 text-emerald-300'
                      : s.status === 'FAILED'
                        ? 'border-red-700/40 bg-red-950/40 text-red-300'
                        : 'border-amber-700/40 bg-amber-950/40 text-amber-300',
                  )}
                >
                  {s.status}
                </span>
                <span className="text-xs text-muted-foreground">
                  {s.alerts} alerts
                </span>
                <ChevronRight className="h-4 w-4 text-muted-foreground" />
              </div>
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}

function Breadcrumbs({
  crumbs,
  onJump,
}: {
  crumbs: Crumb[];
  onJump: (idx: number) => void;
}) {
  return (
    <div className="flex flex-wrap items-center gap-2 text-sm">
      {crumbs.map((c, i) => {
        const isLast = i === crumbs.length - 1;
        return (
          <div key={`${c.level}-${c.key}-${i}`} className="flex items-center gap-2">
            <button
              type="button"
              onClick={() => onJump(i)}
              disabled={isLast}
              className={cn(
                'rounded-md border px-2 py-1 text-xs',
                isLast
                  ? 'border-border bg-secondary text-secondary-foreground cursor-default'
                  : 'border-border bg-card text-muted-foreground hover:bg-secondary/50',
              )}
            >
              <span className="mr-1 text-[10px] uppercase tracking-wide opacity-70">
                {LEVEL_LABEL[c.level]}
              </span>
              <span className="font-medium text-foreground">{c.label}</span>
            </button>
            {!isLast && <ChevronRight className="h-3.5 w-3.5 text-muted-foreground" />}
          </div>
        );
      })}
    </div>
  );
}

function BreakdownPanel({
  level,
  data,
  loading,
  error,
  onDrill,
}: {
  level: DrillLevel | null;
  data?: DrillBreakdown;
  loading: boolean;
  error?: Error;
  onDrill: (node: DrillNode) => void;
}) {
  if (!level) {
    return (
      <EmptyState
        title="Leaf reached"
        body="You are at Store-Article. Inspect raw V_SILVER_LISTING / V_SILVER_ALLOC below."
      />
    );
  }
  if (loading) {
    return (
      <div className="space-y-2">
        {Array.from({ length: 6 }).map((_, i) => (
          <div
            key={i}
            className="h-14 animate-pulse rounded-lg border border-border bg-card"
          />
        ))}
      </div>
    );
  }
  if (error) {
    return (
      <EmptyState
        title="Failed to load breakdown"
        body={error.message}
        tone="error"
      />
    );
  }
  if (!data || !data.rows.length) {
    return (
      <EmptyState title="No rows" body={`No ${LEVEL_LABEL[level]} rows for this branch.`} />
    );
  }

  const { rows, totals } = data;
  return (
    <div className="rounded-lg border border-border bg-card">
      <div className="flex items-center justify-between border-b border-border px-4 py-3">
        <div>
          <div className="text-xs uppercase tracking-wide text-muted-foreground">
            Next level
          </div>
          <div className="text-sm font-medium">{LEVEL_LABEL[level]}</div>
        </div>
        <div className="flex items-center gap-4 text-xs text-muted-foreground">
          <TotalsPill label="Req" value={totals.req} />
          <TotalsPill label="Alloc" value={totals.allocated} tone="ok" />
          <TotalsPill label="Gap" value={totals.gap} tone="warn" />
        </div>
      </div>
      <ul className="divide-y divide-border">
        {rows.map((r) => {
          const pct = gapPct(r.req, r.allocated);
          return (
            <li key={`${r.level}-${r.key}`}>
              <button
                type="button"
                onClick={() => onDrill(r)}
                className="flex w-full flex-col gap-2 px-4 py-3 text-left hover:bg-secondary/50 sm:flex-row sm:items-center sm:gap-4"
              >
                <div className="min-w-0 flex-1">
                  <div className="truncate font-medium">{r.label}</div>
                  <div className="truncate text-xs text-muted-foreground">
                    {r.key}
                  </div>
                </div>
                <div className="grid w-full grid-cols-3 gap-3 sm:w-auto sm:grid-cols-3">
                  <Metric label="Req" value={r.req} />
                  <Metric label="Alloc" value={r.allocated} tone="ok" />
                  <Metric label="Gap" value={r.gap} tone="warn" />
                </div>
                <div className="hidden w-40 shrink-0 sm:block">
                  <GapBar pct={pct} />
                </div>
                <ChevronRight className="hidden h-4 w-4 shrink-0 text-muted-foreground sm:block" />
              </button>
            </li>
          );
        })}
      </ul>
    </div>
  );
}

function TotalsPill({
  label,
  value,
  tone,
}: {
  label: string;
  value: number;
  tone?: 'ok' | 'warn';
}) {
  return (
    <div className="flex items-center gap-1">
      <span className="opacity-70">{label}</span>
      <span
        className={cn(
          'font-medium',
          tone === 'ok' && 'text-emerald-300',
          tone === 'warn' && 'text-amber-300',
          !tone && 'text-foreground',
        )}
      >
        {fmt(value)}
      </span>
    </div>
  );
}

function Metric({
  label,
  value,
  tone,
}: {
  label: string;
  value: number;
  tone?: 'ok' | 'warn';
}) {
  return (
    <div>
      <div className="text-[10px] uppercase tracking-wide text-muted-foreground">
        {label}
      </div>
      <div
        className={cn(
          'text-sm font-medium tabular-nums',
          tone === 'ok' && 'text-emerald-300',
          tone === 'warn' && 'text-amber-300',
        )}
      >
        {fmt(value)}
      </div>
    </div>
  );
}

function GapBar({ pct }: { pct: number }) {
  return (
    <div className="h-2 w-full overflow-hidden rounded-full bg-secondary">
      <div
        className={cn(
          'h-full',
          pct >= 50 ? 'bg-red-500' : pct >= 20 ? 'bg-amber-500' : 'bg-emerald-500',
        )}
        style={{ width: `${pct}%` }}
      />
    </div>
  );
}

function LeafPanel({
  leaf,
  loading,
  active,
}: {
  leaf?: DrillLeaf;
  loading: boolean;
  active: boolean;
}) {
  if (!active) {
    return (
      <div className="rounded-lg border border-dashed border-border bg-card/50 px-4 py-6 text-sm text-muted-foreground">
        <div className="flex items-center gap-2">
          <Database className="h-4 w-4" />
          Drill to a Store-Article leaf to see raw V_SILVER_LISTING and
          V_SILVER_ALLOC rows.
        </div>
      </div>
    );
  }
  if (loading) {
    return (
      <div className="grid gap-4 lg:grid-cols-2">
        <div className="h-64 animate-pulse rounded-lg border border-border bg-card" />
        <div className="h-64 animate-pulse rounded-lg border border-border bg-card" />
      </div>
    );
  }
  if (!leaf) {
    return (
      <EmptyState
        title="No leaf data"
        body="Could not load raw rows for this store-article."
      />
    );
  }
  return (
    <div className="grid gap-4 lg:grid-cols-2">
      <RawCard title="V_SILVER_LISTING" row={leaf.listing} />
      <RawCard title="V_SILVER_ALLOC" row={leaf.alloc} />
    </div>
  );
}

function RawCard({
  title,
  row,
}: {
  title: string;
  row: { source: string; data: Record<string, unknown> } | null;
}) {
  return (
    <div className="rounded-lg border border-border bg-card">
      <div className="flex items-center justify-between border-b border-border px-4 py-3">
        <div className="text-sm font-medium">{title}</div>
        <Database className="h-4 w-4 text-muted-foreground" />
      </div>
      {!row ? (
        <div className="px-4 py-6 text-sm text-muted-foreground">
          No row in {title}.
        </div>
      ) : (
        <dl className="max-h-[480px] divide-y divide-border overflow-auto">
          {Object.entries(row.data).map(([k, v]) => (
            <div
              key={k}
              className="grid grid-cols-2 gap-3 px-4 py-2 text-xs"
            >
              <dt className="truncate text-muted-foreground">{k}</dt>
              <dd className="truncate font-mono tabular-nums text-foreground">
                {v == null ? '—' : String(v)}
              </dd>
            </div>
          ))}
        </dl>
      )}
    </div>
  );
}

function EmptyState({
  title,
  body,
  tone,
}: {
  title: string;
  body: string;
  tone?: 'error';
}) {
  const Icon = tone === 'error' ? AlertTriangle : Loader2;
  return (
    <div
      className={cn(
        'rounded-lg border px-4 py-8 text-center',
        tone === 'error'
          ? 'border-red-900/40 bg-red-950/20'
          : 'border-border bg-card',
      )}
    >
      <Icon
        className={cn(
          'mx-auto mb-2 h-5 w-5',
          tone === 'error' ? 'text-red-400' : 'text-muted-foreground',
        )}
      />
      <div className="text-sm font-medium">{title}</div>
      <div className="text-xs text-muted-foreground">{body}</div>
    </div>
  );
}

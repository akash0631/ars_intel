'use client';

import { useMemo } from 'react';
import useSWR from 'swr';
import {
  LineChart,
  Line,
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  Legend,
  ResponsiveContainer,
} from 'recharts';
import { TrendingDown, TrendingUp, Minus } from 'lucide-react';
import { api, type TrendPoint } from '@/lib/api';
import { ruleLabel } from '@/lib/severity';
import { cn } from '@/lib/utils';

const RANGE_DAYS = 30;

const RULE_COLORS = [
  '#60a5fa', '#f87171', '#fbbf24', '#34d399', '#a78bfa',
  '#f472b6', '#22d3ee', '#fb923c', '#a3e635', '#e879f9',
  '#38bdf8', '#facc15', '#4ade80', '#c084fc', '#fb7185',
];

const toIso = (d: Date) => d.toISOString().slice(0, 10);
const addDays = (d: Date, n: number) => {
  const c = new Date(d);
  c.setDate(c.getDate() + n);
  return c;
};

type ChartRow = { run_date: string } & Record<string, number | string>;

type Regression = {
  rule_id: string;
  this_week: number;
  last_week: number;
  delta: number;
  pct: number;
};

function buildRange(from: string, to: string): string[] {
  const out: string[] = [];
  let d = new Date(from);
  const end = new Date(to);
  while (d <= end) {
    out.push(toIso(d));
    d = addDays(d, 1);
  }
  return out;
}

function pivotByRule(
  points: TrendPoint[],
  dates: string[],
  field: 'count' | 'lost_qty',
): { rows: ChartRow[]; rules: string[] } {
  const rules = Array.from(new Set(points.map((p) => p.rule_id))).sort();
  const byKey = new Map<string, number>();
  for (const p of points) {
    const k = `${p.run_date}__${p.rule_id}`;
    byKey.set(k, (byKey.get(k) ?? 0) + (p[field] ?? 0));
  }
  const rows: ChartRow[] = dates.map((d) => {
    const row: ChartRow = { run_date: d.slice(5) };
    for (const r of rules) row[r] = byKey.get(`${d}__${r}`) ?? 0;
    return row;
  });
  return { rows, rules };
}

function computeRegressions(
  points: TrendPoint[],
  to: string,
): Regression[] {
  const end = new Date(to);
  const thisWeekStart = toIso(addDays(end, -6));
  const lastWeekStart = toIso(addDays(end, -13));
  const lastWeekEnd = toIso(addDays(end, -7));
  const buckets = new Map<string, { tw: number; lw: number }>();
  for (const p of points) {
    if (!buckets.has(p.rule_id)) buckets.set(p.rule_id, { tw: 0, lw: 0 });
    const b = buckets.get(p.rule_id)!;
    if (p.run_date >= thisWeekStart && p.run_date <= to) b.tw += p.lost_qty;
    else if (p.run_date >= lastWeekStart && p.run_date <= lastWeekEnd) b.lw += p.lost_qty;
  }
  const out: Regression[] = [];
  for (const [rule_id, b] of buckets.entries()) {
    const delta = b.tw - b.lw;
    const pct = b.lw === 0 ? (b.tw > 0 ? 100 : 0) : (delta / b.lw) * 100;
    out.push({ rule_id, this_week: b.tw, last_week: b.lw, delta, pct });
  }
  return out.sort((a, b) => b.delta - a.delta);
}

function SkeletonBlock({ h = 'h-72' }: { h?: string }) {
  return <div className={cn('w-full animate-pulse rounded-lg bg-muted/40', h)} />;
}

function EmptyState({ msg }: { msg: string }) {
  return (
    <div className="flex h-72 w-full items-center justify-center rounded-lg border border-dashed border-border text-sm text-muted-foreground">
      {msg}
    </div>
  );
}

export default function TrendsPage() {
  const to = useMemo(() => toIso(new Date()), []);
  const from = useMemo(() => toIso(addDays(new Date(), -(RANGE_DAYS - 1))), []);
  const dates = useMemo(() => buildRange(from, to), [from, to]);

  const { data, error, isLoading } = useSWR<TrendPoint[]>(
    ['trends', from, to],
    () => api.alertsTrends({ from, to }),
    { revalidateOnFocus: false },
  );

  const lineData = useMemo(() => {
    if (!data) return { rows: [], rules: [] as string[] };
    return pivotByRule(data, dates, 'count');
  }, [data, dates]);

  const barData = useMemo(() => {
    if (!data) return { rows: [], rules: [] as string[] };
    return pivotByRule(data, dates, 'lost_qty');
  }, [data, dates]);

  const regressions = useMemo(() => {
    if (!data) return [];
    return computeRegressions(data, to);
  }, [data, to]);

  const hasData = (data?.length ?? 0) > 0;

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h2 className="text-xl font-semibold tracking-tight">Trends</h2>
        <p className="text-sm text-muted-foreground">
          Last {RANGE_DAYS} days · {from} → {to}
        </p>
      </div>

      {error && (
        <div className="rounded-lg border border-severity-crit/40 bg-severity-crit/10 px-4 py-3 text-sm text-severity-crit">
          Failed to load trends: {error.message}
        </div>
      )}

      <section className="rounded-lg border border-border bg-card p-4 shadow-sm">
        <div className="mb-3 flex items-center justify-between">
          <div>
            <h3 className="text-sm font-medium">Alert count per rule</h3>
            <p className="text-xs text-muted-foreground">Daily alert count, last 30 days</p>
          </div>
        </div>
        {isLoading ? (
          <SkeletonBlock />
        ) : !hasData ? (
          <EmptyState msg="No trend data available for this window." />
        ) : (
          <div className="h-72 w-full">
            <ResponsiveContainer width="100%" height="100%">
              <LineChart data={lineData.rows} margin={{ top: 8, right: 12, left: 0, bottom: 0 }}>
                <CartesianGrid stroke="hsl(var(--border))" strokeDasharray="3 3" />
                <XAxis
                  dataKey="run_date"
                  stroke="hsl(var(--muted-foreground))"
                  fontSize={11}
                  tickMargin={6}
                />
                <YAxis stroke="hsl(var(--muted-foreground))" fontSize={11} width={36} />
                <Tooltip
                  contentStyle={{
                    background: 'hsl(var(--popover))',
                    border: '1px solid hsl(var(--border))',
                    borderRadius: 6,
                    fontSize: 12,
                  }}
                  labelStyle={{ color: 'hsl(var(--foreground))' }}
                />
                <Legend wrapperStyle={{ fontSize: 11 }} />
                {lineData.rules.map((r, i) => (
                  <Line
                    key={r}
                    type="monotone"
                    dataKey={r}
                    name={ruleLabel(r)}
                    stroke={RULE_COLORS[i % RULE_COLORS.length]}
                    strokeWidth={1.6}
                    dot={false}
                    activeDot={{ r: 3 }}
                  />
                ))}
              </LineChart>
            </ResponsiveContainer>
          </div>
        )}
      </section>

      <section className="rounded-lg border border-border bg-card p-4 shadow-sm">
        <div className="mb-3">
          <h3 className="text-sm font-medium">Lost quantity by rule (stacked)</h3>
          <p className="text-xs text-muted-foreground">Daily lost qty contribution per rule</p>
        </div>
        {isLoading ? (
          <SkeletonBlock />
        ) : !hasData ? (
          <EmptyState msg="No lost quantity data for this window." />
        ) : (
          <div className="h-80 w-full">
            <ResponsiveContainer width="100%" height="100%">
              <BarChart data={barData.rows} margin={{ top: 8, right: 12, left: 0, bottom: 0 }}>
                <CartesianGrid stroke="hsl(var(--border))" strokeDasharray="3 3" />
                <XAxis
                  dataKey="run_date"
                  stroke="hsl(var(--muted-foreground))"
                  fontSize={11}
                  tickMargin={6}
                />
                <YAxis stroke="hsl(var(--muted-foreground))" fontSize={11} width={40} />
                <Tooltip
                  contentStyle={{
                    background: 'hsl(var(--popover))',
                    border: '1px solid hsl(var(--border))',
                    borderRadius: 6,
                    fontSize: 12,
                  }}
                  labelStyle={{ color: 'hsl(var(--foreground))' }}
                />
                <Legend wrapperStyle={{ fontSize: 11 }} />
                {barData.rules.map((r, i) => (
                  <Bar
                    key={r}
                    dataKey={r}
                    name={ruleLabel(r)}
                    stackId="lost"
                    fill={RULE_COLORS[i % RULE_COLORS.length]}
                  />
                ))}
              </BarChart>
            </ResponsiveContainer>
          </div>
        )}
      </section>

      <section className="rounded-lg border border-border bg-card p-4 shadow-sm">
        <div className="mb-3">
          <h3 className="text-sm font-medium">Week-over-week regressions</h3>
          <p className="text-xs text-muted-foreground">
            Lost qty change: trailing 7d vs prior 7d
          </p>
        </div>
        {isLoading ? (
          <SkeletonBlock h="h-48" />
        ) : regressions.length === 0 ? (
          <EmptyState msg="No regressions to report." />
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full min-w-[640px] text-sm">
              <thead>
                <tr className="border-b border-border text-left text-xs uppercase tracking-wide text-muted-foreground">
                  <th className="px-3 py-2 font-medium">Rule</th>
                  <th className="px-3 py-2 text-right font-medium">This week</th>
                  <th className="px-3 py-2 text-right font-medium">Last week</th>
                  <th className="px-3 py-2 text-right font-medium">Delta</th>
                  <th className="px-3 py-2 text-right font-medium">% change</th>
                </tr>
              </thead>
              <tbody>
                {regressions.map((r) => {
                  const up = r.delta > 0;
                  const down = r.delta < 0;
                  const Icon = up ? TrendingUp : down ? TrendingDown : Minus;
                  const tone = up
                    ? 'text-severity-crit'
                    : down
                      ? 'text-severity-low'
                      : 'text-muted-foreground';
                  return (
                    <tr key={r.rule_id} className="border-b border-border/60 last:border-0">
                      <td className="px-3 py-2">
                        <div className="font-medium">{ruleLabel(r.rule_id)}</div>
                        <div className="text-xs text-muted-foreground">{r.rule_id}</div>
                      </td>
                      <td className="px-3 py-2 text-right tabular-nums">
                        {r.this_week.toLocaleString()}
                      </td>
                      <td className="px-3 py-2 text-right tabular-nums text-muted-foreground">
                        {r.last_week.toLocaleString()}
                      </td>
                      <td className={cn('px-3 py-2 text-right tabular-nums', tone)}>
                        <span className="inline-flex items-center justify-end gap-1">
                          <Icon className="h-3.5 w-3.5" />
                          {r.delta > 0 ? '+' : ''}
                          {r.delta.toLocaleString()}
                        </span>
                      </td>
                      <td className={cn('px-3 py-2 text-right tabular-nums', tone)}>
                        {r.pct > 0 ? '+' : ''}
                        {r.pct.toFixed(1)}%
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </div>
  );
}

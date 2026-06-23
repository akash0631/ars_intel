// API client hitting CF Worker at /api/*
// Endpoints:
//   GET /api/alerts/top?run_date=YYYY-MM-DD&limit=...
//   GET /api/alerts/trends?from=YYYY-MM-DD&to=YYYY-MM-DD
//   GET /api/drill/sessions?run_date=...
//   GET /api/drill/store-majcat?store=...&majcat=...&run_date=...

export const API_BASE =
  (typeof process !== 'undefined' && process.env.NEXT_PUBLIC_API_BASE) || '';

export type AlertRow = {
  alert_id: string;
  run_date: string;
  store: string;
  majcat: string;
  rule_id: string;
  severity: 'low' | 'med' | 'high' | 'crit';
  lost_qty: number;
  root_cause: string;
  fix_action: string;
  details?: Record<string, unknown>;
};

export type TrendPoint = {
  run_date: string;
  rule_id: string;
  severity: string;
  count: number;
  lost_qty: number;
};

export type SessionRow = {
  session_id: string;
  run_date: string;
  store: string;
  majcat: string;
  status: string;
  alerts: number;
};

export type StoreMajcatDrill = {
  store: string;
  majcat: string;
  run_date: string;
  alerts: AlertRow[];
  metrics: Record<string, number>;
};

export class ApiError extends Error {
  status: number;
  constructor(message: string, status: number) {
    super(message);
    this.status = status;
  }
}

export const fetcher = async <T>(path: string): Promise<T> => {
  const url = path.startsWith('http') ? path : `${API_BASE}${path}`;
  const res = await fetch(url, {
    headers: { Accept: 'application/json' },
    cache: 'no-store',
  });
  if (!res.ok) {
    throw new ApiError(`API ${res.status} on ${path}`, res.status);
  }
  return (await res.json()) as T;
};

export const qs = (params: Record<string, string | number | undefined>) => {
  const sp = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) {
    if (v !== undefined && v !== null && v !== '') sp.set(k, String(v));
  }
  const s = sp.toString();
  return s ? `?${s}` : '';
};

export type DrillLevel =
  | 'session'
  | 'majcat'
  | 'grid'
  | 'combo'
  | 'size'
  | 'store_article';

export type DrillNode = {
  level: DrillLevel;
  key: string;
  label: string;
  req: number;
  allocated: number;
  gap: number;
  shipped?: number;
  hold?: number;
  meta?: Record<string, string | number | null>;
};

export type DrillBreakdown = {
  level: DrillLevel;
  parent_key?: string;
  session_id: string;
  rows: DrillNode[];
  totals: { req: number; allocated: number; gap: number };
};

export type DrillLeafRow = {
  source: 'V_SILVER_LISTING' | 'V_SILVER_ALLOC';
  data: Record<string, unknown>;
};

export type DrillLeaf = {
  session_id: string;
  store: string;
  article: string;
  listing: DrillLeafRow | null;
  alloc: DrillLeafRow | null;
};

export const api = {
  alertsTop: (params: { run_date?: string; limit?: number } = {}) =>
    fetcher<AlertRow[]>(`/api/alerts/top${qs(params)}`),
  alertsTrends: (params: { from?: string; to?: string } = {}) =>
    fetcher<TrendPoint[]>(`/api/alerts/trends${qs(params)}`),
  drillSessions: (params: { run_date?: string } = {}) =>
    fetcher<SessionRow[]>(`/api/drill/sessions${qs(params)}`),
  drillStoreMajcat: (params: {
    store: string;
    majcat: string;
    run_date?: string;
  }) => fetcher<StoreMajcatDrill>(`/api/drill/store-majcat${qs(params)}`),
  drillBreakdown: (params: {
    session_id: string;
    level: DrillLevel;
    majcat?: string;
    grid_attr?: string;
    combo?: string;
    size?: string;
    store?: string;
  }) => fetcher<DrillBreakdown>(`/api/drill/breakdown${qs(params)}`),
  drillLeaf: (params: {
    session_id: string;
    store: string;
    article: string;
  }) => fetcher<DrillLeaf>(`/api/drill/leaf${qs(params)}`),
};

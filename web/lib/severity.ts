export type Severity = 'low' | 'med' | 'high' | 'crit';

export const SEVERITY_ORDER: Severity[] = ['low', 'med', 'high', 'crit'];

export const SEVERITY_WEIGHT: Record<Severity, number> = {
  low: 1,
  med: 2,
  high: 3,
  crit: 4,
};

// Tailwind background / text / border classes per severity bucket.
export const SEVERITY_BG: Record<Severity, string> = {
  low: 'bg-severity-low/20 text-severity-low border-severity-low/40',
  med: 'bg-severity-med/20 text-severity-med border-severity-med/40',
  high: 'bg-severity-high/20 text-severity-high border-severity-high/40',
  crit: 'bg-severity-crit/20 text-severity-crit border-severity-crit/40',
};

export const SEVERITY_SOLID: Record<Severity, string> = {
  low: 'bg-severity-low',
  med: 'bg-severity-med',
  high: 'bg-severity-high',
  crit: 'bg-severity-crit',
};

export const SEVERITY_LABEL: Record<Severity, string> = {
  low: 'Low',
  med: 'Medium',
  high: 'High',
  crit: 'Critical',
};

// Heatmap cell shade based on accumulated severity score (sum of weights).
export const heatmapShade = (score: number): string => {
  if (score <= 0) return 'bg-muted/30';
  if (score < 2) return 'bg-severity-low/30';
  if (score < 5) return 'bg-severity-med/40';
  if (score < 10) return 'bg-severity-high/60';
  return 'bg-severity-crit/80';
};

// rule_id → human label
export const RULE_LABEL: Record<string, string> = {
  R001: 'Zero on-hand, demand present',
  R002: 'Demand spike vs forecast',
  R003: 'Over-allocation vs MSQ',
  R004: 'Under-allocation vs MSQ',
  R005: 'Aging stock, no replen',
  R006: 'New article, no allocation',
  R007: 'Store closed, allocated',
  R008: 'Performance bucket drop',
  R009: 'GP PSF below threshold',
  R010: 'Size grid mismatch',
  R011: 'Cluster mismatch',
  R012: 'DC out of stock',
  R013: 'Returns spike',
  R014: 'Stale forecast',
  R015: 'MOQ violation',
};

export const ruleLabel = (id: string): string => RULE_LABEL[id] ?? id;

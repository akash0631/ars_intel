'use client';

import { useState } from 'react';
import { ChevronDown, ChevronRight, Wrench } from 'lucide-react';
import type { AlertRow } from '@/lib/api';
import { SEVERITY_BG, SEVERITY_LABEL, ruleLabel } from '@/lib/severity';
import { cn } from '@/lib/utils';

interface AlertCardProps {
  alert: AlertRow;
  onFix?: (alert: AlertRow) => void;
  defaultOpen?: boolean;
}

export function AlertCard({ alert, onFix, defaultOpen = false }: AlertCardProps) {
  const [open, setOpen] = useState(defaultOpen);
  const sev = alert.severity;
  return (
    <div className="rounded-lg border border-border bg-card text-card-foreground shadow-sm">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        className="flex w-full items-center justify-between gap-3 px-4 py-3 text-left"
      >
        <div className="flex min-w-0 items-center gap-3">
          {open ? (
            <ChevronDown className="h-4 w-4 shrink-0 text-muted-foreground" />
          ) : (
            <ChevronRight className="h-4 w-4 shrink-0 text-muted-foreground" />
          )}
          <div className="min-w-0">
            <div className="flex flex-wrap items-center gap-2">
              <span className="font-medium">{alert.store}</span>
              <span className="text-muted-foreground">·</span>
              <span className="text-sm text-muted-foreground">{alert.majcat}</span>
              <span className="text-muted-foreground">·</span>
              <span className="text-sm">{ruleLabel(alert.rule_id)}</span>
            </div>
          </div>
        </div>
        <div className="flex shrink-0 items-center gap-3">
          <span className="text-sm text-muted-foreground">
            Lost qty <span className="font-medium text-foreground">{alert.lost_qty}</span>
          </span>
          <span
            className={cn(
              'rounded-md border px-2 py-0.5 text-xs font-medium',
              SEVERITY_BG[sev],
            )}
          >
            {SEVERITY_LABEL[sev]}
          </span>
        </div>
      </button>
      {open && (
        <div className="border-t border-border px-4 py-3 text-sm">
          <div className="mb-3">
            <div className="mb-1 text-xs uppercase tracking-wide text-muted-foreground">
              Root cause
            </div>
            <div>{alert.root_cause}</div>
          </div>
          <div className="flex items-start justify-between gap-3">
            <div className="min-w-0">
              <div className="mb-1 text-xs uppercase tracking-wide text-muted-foreground">
                Suggested fix
              </div>
              <div>{alert.fix_action}</div>
            </div>
            <button
              type="button"
              onClick={() => onFix?.(alert)}
              className="inline-flex shrink-0 items-center gap-2 rounded-md bg-primary px-3 py-1.5 text-xs font-medium text-primary-foreground hover:bg-primary/90"
            >
              <Wrench className="h-3.5 w-3.5" />
              Apply fix
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

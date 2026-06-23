'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { CalendarDays, TrendingUp, Layers } from 'lucide-react';
import { cn } from '@/lib/utils';

const TABS = [
  { href: '/today', label: 'Today', icon: CalendarDays },
  { href: '/trends', label: 'Trends', icon: TrendingUp },
  { href: '/drill', label: 'Drill', icon: Layers },
];

export function SidebarNav() {
  const pathname = usePathname();
  return (
    <nav className="flex flex-col gap-1">
      {TABS.map((tab) => {
        const active = pathname?.startsWith(tab.href);
        const Icon = tab.icon;
        return (
          <Link
            key={tab.href}
            href={tab.href}
            className={cn(
              'flex items-center gap-2 rounded-md px-3 py-2 text-sm font-medium transition-colors',
              active
                ? 'bg-secondary text-secondary-foreground'
                : 'text-muted-foreground hover:bg-secondary/50 hover:text-foreground',
            )}
          >
            <Icon className="h-4 w-4" />
            {tab.label}
          </Link>
        );
      })}
    </nav>
  );
}

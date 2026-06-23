import type { Metadata } from 'next';
import './globals.css';
import { SidebarNav } from '@/components/SidebarNav';

export const metadata: Metadata = {
  title: 'ARS Intelligence',
  description: 'Allocation Replenishment System intelligence dashboard',
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" className="dark">
      <body className="min-h-screen bg-background text-foreground antialiased">
        <header className="sticky top-0 z-40 border-b border-border bg-background/95 backdrop-blur supports-[backdrop-filter]:bg-background/60">
          <div className="container mx-auto flex h-14 items-center justify-between px-4">
            <div className="flex items-center gap-3">
              <h1 className="text-lg font-semibold tracking-tight">
                ARS Intelligence
              </h1>
            </div>
            <div className="flex items-center gap-3">
              <label htmlFor="run-date" className="text-sm text-muted-foreground">
                Run date
              </label>
              <input
                id="run-date"
                type="date"
                className="h-9 rounded-md border border-input bg-background px-3 text-sm shadow-sm focus:outline-none focus:ring-2 focus:ring-ring"
                defaultValue={new Date().toISOString().slice(0, 10)}
              />
            </div>
          </div>
        </header>
        <div className="container mx-auto flex gap-6 px-4 py-6">
          <aside className="w-48 shrink-0">
            <SidebarNav />
          </aside>
          <main className="flex-1 min-w-0">{children}</main>
        </div>
      </body>
    </html>
  );
}

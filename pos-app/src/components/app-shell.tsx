"use client";

import {
  BarChart3,
  Boxes,
  ClipboardCheck,
  FileText,
  LayoutDashboard,
  LogOut,
  Menu,
  PanelRightClose,
  PanelRightOpen,
  Settings,
  ShieldCheck,
  Shirt,
  ShoppingCart,
  Truck,
  Undo2,
  UserCog,
  Users,
  PackagePlus,
  Wallet,
  HandCoins,
  Lightbulb,
  BookmarkCheck,
  BadgePercent,
  X,
} from "lucide-react";
import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useEffect, useState, type ReactNode } from "react";
import { ROLE_LABELS } from "@/lib/format";
import { supabase } from "@/lib/supabase/client";
import type { Profile, StoreSettings, UserRole } from "@/lib/types";
import { SessionProvider } from "./session-context";
import { cn, ToastProvider } from "./ui";

interface NavItem {
  href: string;
  label: string;
  icon: typeof LayoutDashboard;
  roles: UserRole[];
}

const M: UserRole[] = ["owner", "manager"];
const ALL: UserRole[] = ["owner", "manager", "cashier"];

const NAV: NavItem[] = [
  { href: "/dashboard", label: "لوحة التحكم", icon: LayoutDashboard, roles: M },
  { href: "/pos", label: "نقطة البيع", icon: ShoppingCart, roles: ALL },
  { href: "/sales", label: "الفواتير", icon: FileText, roles: ALL },
  { href: "/returns", label: "المرتجعات والاستبدال", icon: Undo2, roles: ALL },
  { href: "/shifts", label: "الورديات", icon: Wallet, roles: ALL },
  { href: "/products", label: "المنتجات", icon: Shirt, roles: M },
  { href: "/inventory", label: "المخزون", icon: Boxes, roles: M },
  { href: "/inventory/counts", label: "الجرد", icon: ClipboardCheck, roles: ALL },
  { href: "/purchases", label: "المشتريات", icon: PackagePlus, roles: M },
  { href: "/advisor", label: "مساعد الشراء الذكي", icon: Lightbulb, roles: M },
  { href: "/suppliers", label: "الموردون", icon: Truck, roles: M },
  { href: "/expenses", label: "المصروفات", icon: HandCoins, roles: M },
  { href: "/customers", label: "العملاء", icon: Users, roles: ALL },
  { href: "/reservations", label: "الحجوزات", icon: BookmarkCheck, roles: ALL },
  { href: "/promotions", label: "العروض والخصومات", icon: BadgePercent, roles: M },
  { href: "/reports", label: "التقارير", icon: BarChart3, roles: M },
  { href: "/users", label: "المستخدمون", icon: UserCog, roles: ["owner"] },
  { href: "/audit", label: "سجل التدقيق", icon: ShieldCheck, roles: ["owner"] },
  { href: "/settings", label: "الإعدادات", icon: Settings, roles: ["owner"] },
];

function isActive(pathname: string, href: string) {
  if (href === "/inventory") return pathname === "/inventory" || pathname.startsWith("/inventory/movements");
  return pathname === href || pathname.startsWith(href + "/");
}

export function AppShell({
  profile,
  settings,
  children,
}: {
  profile: Profile;
  settings: StoreSettings;
  children: ReactNode;
}) {
  const pathname = usePathname();
  const router = useRouter();
  const [drawer, setDrawer] = useState(false);
  const [collapsed, setCollapsed] = useState(false);
  const items = NAV.filter((n) => n.roles.includes(profile.role));

  useEffect(() => {
    try {
      setCollapsed(localStorage.getItem("sidebar-collapsed") === "1");
    } catch {
      /* storage unavailable */
    }
  }, []);

  const toggleCollapsed = () => {
    setCollapsed((c) => {
      try {
        localStorage.setItem("sidebar-collapsed", c ? "0" : "1");
      } catch {
        /* storage unavailable */
      }
      return !c;
    });
  };

  const signOut = async () => {
    await supabase().auth.signOut();
    router.replace("/login");
    router.refresh();
  };

  const nav = (compact: boolean) => (
    <nav className="flex flex-1 flex-col gap-0.5 overflow-y-auto px-2 py-3 scrollbar-thin">
      {items.map((item) => {
        const active = isActive(pathname, item.href);
        const Icon = item.icon;
        return (
          <Link
            key={item.href}
            href={item.href}
            onClick={() => setDrawer(false)}
            title={compact ? item.label : undefined}
            className={cn(
              "flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium transition-colors",
              active ? "bg-brand-700 text-white" : "text-slate-300 hover:bg-white/10 hover:text-white",
              compact && "justify-center px-0",
            )}
          >
            <Icon className="size-5 shrink-0" />
            {!compact && <span className="truncate">{item.label}</span>}
          </Link>
        );
      })}
    </nav>
  );

  const userBox = (compact: boolean) => (
    <div className="border-t border-white/10 p-3">
      {!compact && (
        <div className="mb-2 px-1">
          <p className="truncate text-sm font-medium text-white">{profile.full_name || profile.email}</p>
          <p className="text-xs text-slate-400">{ROLE_LABELS[profile.role]}</p>
        </div>
      )}
      <button
        onClick={signOut}
        className={cn(
          "flex w-full items-center gap-2 rounded-lg px-3 py-2 text-sm text-slate-300 hover:bg-white/10 hover:text-white",
          compact && "justify-center px-0",
        )}
        title="تسجيل الخروج"
      >
        <LogOut className="size-4" />
        {!compact && "تسجيل الخروج"}
      </button>
    </div>
  );

  return (
    <SessionProvider value={{ profile, settings }}>
      <ToastProvider>
        <div className="flex min-h-dvh">
          {/* Desktop sidebar */}
          <aside
            className={cn(
              "no-print sticky top-0 hidden h-dvh shrink-0 flex-col bg-slate-900 lg:flex",
              collapsed ? "w-16" : "w-60",
            )}
          >
            <div className={cn("flex h-14 items-center gap-2 border-b border-white/10 px-3", collapsed && "justify-center")}>
              {!collapsed && <span className="flex-1 truncate font-bold text-white">{settings.store_name}</span>}
              <button
                onClick={toggleCollapsed}
                className="rounded-md p-1.5 text-slate-400 hover:bg-white/10 hover:text-white"
                aria-label="طي القائمة"
              >
                {collapsed ? <PanelRightOpen className="size-5" /> : <PanelRightClose className="size-5" />}
              </button>
            </div>
            {nav(collapsed)}
            {userBox(collapsed)}
          </aside>

          {/* Mobile drawer */}
          {drawer && (
            <div className="no-print fixed inset-0 z-40 lg:hidden">
              <div className="absolute inset-0 bg-slate-900/60" onClick={() => setDrawer(false)} />
              <aside className="absolute inset-y-0 right-0 flex w-72 flex-col bg-slate-900">
                <div className="flex h-14 items-center justify-between border-b border-white/10 px-4">
                  <span className="font-bold text-white">{settings.store_name}</span>
                  <button onClick={() => setDrawer(false)} className="p-1 text-slate-300" aria-label="إغلاق">
                    <X className="size-5" />
                  </button>
                </div>
                {nav(false)}
                {userBox(false)}
              </aside>
            </div>
          )}

          <div className="flex min-w-0 flex-1 flex-col">
            <header className="no-print sticky top-0 z-30 flex h-14 items-center gap-3 border-b border-slate-200 bg-white px-4 lg:hidden">
              <button onClick={() => setDrawer(true)} className="rounded-md p-1.5 text-slate-700" aria-label="القائمة">
                <Menu className="size-6" />
              </button>
              <span className="truncate font-bold">{settings.store_name}</span>
            </header>
            <main className="min-w-0 flex-1">{children}</main>
          </div>
        </div>
      </ToastProvider>
    </SessionProvider>
  );
}

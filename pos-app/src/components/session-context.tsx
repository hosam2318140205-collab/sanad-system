"use client";

import { createContext, useContext, type ReactNode } from "react";
import type { Profile, StoreSettings, UserRole } from "@/lib/types";

interface SessionValue {
  profile: Profile;
  settings: StoreSettings;
}

const SessionContext = createContext<SessionValue | null>(null);

export function SessionProvider({ value, children }: { value: SessionValue; children: ReactNode }) {
  return <SessionContext.Provider value={value}>{children}</SessionContext.Provider>;
}

export function useSession(): SessionValue & { isManager: boolean; isOwner: boolean; can: (...r: UserRole[]) => boolean } {
  const ctx = useContext(SessionContext);
  if (!ctx) throw new Error("useSession must be used inside SessionProvider");
  const role = ctx.profile.role;
  return {
    ...ctx,
    isManager: role === "owner" || role === "manager",
    isOwner: role === "owner",
    can: (...roles) => roles.includes(role),
  };
}

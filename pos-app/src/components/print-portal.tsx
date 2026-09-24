"use client";

import { useSyncExternalStore, type ReactNode } from "react";
import { createPortal } from "react-dom";

const subscribe = () => () => {};

/** Renders children directly under <body>, hidden on screen and the only thing printed. */
export function PrintPortal({ children }: { children: ReactNode }) {
  const mounted = useSyncExternalStore(
    subscribe,
    () => true,
    () => false,
  );
  if (!mounted) return null;
  return createPortal(<div className="print-area print-only">{children}</div>, document.body);
}

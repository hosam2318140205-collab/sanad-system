"use client";

import {
  Banknote,
  CreditCard,
  Landmark,
  Minus,
  PauseCircle,
  PlayCircle,
  Plus,
  RefreshCw,
  ScanBarcode,
  Search,
  ShoppingBag,
  Trash2,
  UserPlus,
  UserRound,
  X,
} from "lucide-react";
import { useRouter, useSearchParams } from "next/navigation";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { ReceiptModal } from "@/components/receipt-modal";
import type { ReceiptData } from "@/components/receipt";
import { useSession } from "@/components/session-context";
import { Badge, Button, Field, Input, Modal, cn, useToast } from "@/components/ui";
import { fetchCatalog, fetchCategories, normalize } from "@/lib/catalog";
import { PAYMENT_LABELS, errorMessage, money, round2, variantLabel } from "@/lib/format";
import { computeTotals } from "@/lib/pricing";
import { loadReceipt } from "@/lib/sales";
import { supabase } from "@/lib/supabase/client";
import type { CatalogItem, Category, Customer, PaymentMethod, ReturnRecord } from "@/lib/types";

interface CartLine {
  item: CatalogItem;
  qty: number;
  discount: number;
}

interface HeldCart {
  id: string;
  at: string;
  lines: CartLine[];
  customer: Customer | null;
  label: string;
}

interface PaymentRow {
  method: Exclude<PaymentMethod, "exchange_credit">;
  amount: string;
  reference: string;
}

const HELD_KEY = "pos-held-carts";

function readHeld(): HeldCart[] {
  try {
    return JSON.parse(localStorage.getItem(HELD_KEY) ?? "[]") as HeldCart[];
  } catch {
    return [];
  }
}
function writeHeld(list: HeldCart[]) {
  try {
    localStorage.setItem(HELD_KEY, JSON.stringify(list));
  } catch {
    /* storage unavailable */
  }
}

export function PosScreen() {
  const { settings, profile } = useSession();
  const toast = useToast();
  const router = useRouter();
  const searchParams = useSearchParams();
  const creditId = searchParams.get("credit");

  const [catalog, setCatalog] = useState<CatalogItem[]>([]);
  const [categories, setCategories] = useState<Category[]>([]);
  const [loading, setLoading] = useState(true);
  const [query, setQuery] = useState("");
  const [category, setCategory] = useState<string | null>(null);
  const [cart, setCart] = useState<CartLine[]>([]);
  const [customer, setCustomer] = useState<Customer | null>(null);
  const [invoiceDiscount, setInvoiceDiscount] = useState("");
  const [discountMode, setDiscountMode] = useState<"amount" | "percent">("amount");
  const [picker, setPicker] = useState<string | null>(null); // product_id
  const [showCustomer, setShowCustomer] = useState(false);
  const [showPay, setShowPay] = useState(false);
  const [showHeld, setShowHeld] = useState(false);
  const [held, setHeld] = useState<HeldCart[]>([]);
  const [mobileCart, setMobileCart] = useState(false);
  const [receipt, setReceipt] = useState<ReceiptData | null>(null);
  const [credit, setCredit] = useState<ReturnRecord | null>(null);
  const [editLine, setEditLine] = useState<string | null>(null);
  const searchRef = useRef<HTMLInputElement>(null);

  const focusSearch = useCallback(() => {
    setTimeout(() => searchRef.current?.focus(), 30);
  }, []);

  const loadCatalog = useCallback(async () => {
    setLoading(true);
    try {
      const [items, cats] = await Promise.all([fetchCatalog(), fetchCategories()]);
      setCatalog(items);
      setCategories(cats);
    } catch (e) {
      toast(errorMessage(e), "error");
    } finally {
      setLoading(false);
    }
  }, [toast]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial data load
    loadCatalog();
    setHeld(readHeld());
  }, [loadCatalog]);

  // رصيد الاستبدال القادم من شاشة المرتجعات
  useEffect(() => {
    if (!creditId) return;
    supabase()
      .from("returns")
      .select("*")
      .eq("id", creditId)
      .maybeSingle()
      .then(({ data }) => {
        const r = data as ReturnRecord | null;
        if (r && r.refund_method === "exchange" && !r.credit_used_by_sale) setCredit(r);
        else toast("رصيد الاستبدال غير متاح أو مستخدم", "error");
      });
  }, [creditId, toast]);

  // ---------------------------------------------------------------- derived
  const products = useMemo(() => {
    const map = new Map<string, { product_id: string; name: string; image_url: string | null; category_id: string | null; variants: CatalogItem[] }>();
    for (const v of catalog) {
      let p = map.get(v.product_id);
      if (!p) {
        p = { product_id: v.product_id, name: v.product_name, image_url: v.image_url, category_id: v.category_id, variants: [] };
        map.set(v.product_id, p);
      }
      p.variants.push(v);
    }
    return [...map.values()];
  }, [catalog]);

  const filtered = useMemo(() => {
    const q = normalize(query);
    return products.filter((p) => {
      if (category && p.category_id !== category) return false;
      if (!q) return true;
      return (
        normalize(p.name).includes(q) ||
        p.variants.some((v) => v.sku.toLowerCase().includes(q) || v.barcode?.includes(q))
      );
    });
  }, [products, query, category]);

  const vatRate = Number(settings.vat_rate);
  const lineDiscountBase = cart.reduce((s, l) => s + round2(l.item.price * l.qty) - (l.discount || 0), 0);
  const invDiscountAmount =
    discountMode === "percent"
      ? round2((lineDiscountBase * (Number(invoiceDiscount) || 0)) / 100)
      : Number(invoiceDiscount) || 0;

  const totals = useMemo(
    () =>
      computeTotals(
        cart.map((l) => ({ price: l.item.price, qty: l.qty, discount: l.discount })),
        invDiscountAmount,
        vatRate,
        settings.prices_include_vat,
      ),
    [cart, invDiscountAmount, vatRate, settings.prices_include_vat],
  );
  const itemsCount = cart.reduce((s, l) => s + l.qty, 0);
  const discountPct = totals.gross > 0 ? (totals.discountTotal / totals.gross) * 100 : 0;
  const overLimit = profile.role === "cashier" && discountPct > Number(settings.max_cashier_discount_pct) + 0.001;

  // ---------------------------------------------------------------- cart ops
  const addToCart = useCallback(
    (item: CatalogItem, qty = 1) => {
      setCart((prev) => {
        const existing = prev.find((l) => l.item.variant_id === item.variant_id);
        const inCart = existing?.qty ?? 0;
        if (!settings.allow_negative_stock && inCart + qty > item.stock_qty) {
          toast(`الكمية المتوفرة من ${item.product_name} (${variantLabel(item.size, item.color)}) هي ${item.stock_qty} فقط`, "error");
          return prev;
        }
        if (existing) {
          return prev.map((l) => (l.item.variant_id === item.variant_id ? { ...l, qty: l.qty + qty } : l));
        }
        return [...prev, { item, qty, discount: 0 }];
      });
    },
    [settings.allow_negative_stock, toast],
  );

  const setQty = (variantId: string, qty: number) => {
    setCart((prev) =>
      prev.flatMap((l) => {
        if (l.item.variant_id !== variantId) return [l];
        if (qty <= 0) return [];
        if (!settings.allow_negative_stock && qty > l.item.stock_qty) {
          toast(`المتوفر ${l.item.stock_qty} فقط`, "error");
          return [l];
        }
        return [{ ...l, qty, discount: Math.min(l.discount, round2(l.item.price * qty)) }];
      }),
    );
  };

  const setLineDiscount = (variantId: string, discount: number) => {
    setCart((prev) =>
      prev.map((l) =>
        l.item.variant_id === variantId
          ? { ...l, discount: Math.max(0, Math.min(discount, round2(l.item.price * l.qty))) }
          : l,
      ),
    );
  };

  const clearSale = useCallback(() => {
    setCart([]);
    setCustomer(null);
    setInvoiceDiscount("");
    setMobileCart(false);
    if (creditId) router.replace("/pos");
    setCredit(null);
    focusSearch();
  }, [creditId, focusSearch, router]);

  const onProductClick = (productId: string) => {
    const p = products.find((x) => x.product_id === productId);
    if (!p) return;
    if (p.variants.length === 1) {
      addToCart(p.variants[0]);
      focusSearch();
    } else {
      setPicker(productId);
    }
  };

  // باركود / SKU: Enter يضيف مباشرة
  const onSearchEnter = () => {
    const code = query.trim();
    if (!code) return;
    const lower = code.toLowerCase();
    const exact = catalog.find((v) => v.barcode === code || v.sku.toLowerCase() === lower);
    if (exact) {
      addToCart(exact);
      setQuery("");
      return;
    }
    if (filtered.length === 1) {
      onProductClick(filtered[0].product_id);
      setQuery("");
      return;
    }
    if (filtered.length === 0) toast(`لا يوجد صنف بالرمز ${code}`, "error");
  };

  // ---------------------------------------------------------------- held carts
  const holdCart = () => {
    if (cart.length === 0) return;
    const entry: HeldCart = {
      id: crypto.randomUUID(),
      at: new Date().toISOString(),
      lines: cart,
      customer,
      label: customer?.name ?? `فاتورة معلقة ${held.length + 1}`,
    };
    const list = [...held, entry];
    setHeld(list);
    writeHeld(list);
    setCart([]);
    setCustomer(null);
    setInvoiceDiscount("");
    toast("تم تعليق الفاتورة", "info");
    focusSearch();
  };

  const resumeHeld = (id: string) => {
    const entry = held.find((h) => h.id === id);
    if (!entry) return;
    if (cart.length > 0) {
      toast("أكمل أو علّق الفاتورة الحالية أولاً", "error");
      return;
    }
    // تحديث الأسعار والمخزون من الكتالوج الحالي
    const lines = entry.lines
      .map((l) => {
        const fresh = catalog.find((c) => c.variant_id === l.item.variant_id);
        return fresh ? { ...l, item: fresh } : null;
      })
      .filter((l): l is CartLine => l !== null);
    setCart(lines);
    setCustomer(entry.customer);
    const list = held.filter((h) => h.id !== id);
    setHeld(list);
    writeHeld(list);
    setShowHeld(false);
  };

  // ---------------------------------------------------------------- keyboard
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === "F2") {
        e.preventDefault();
        searchRef.current?.focus();
      } else if (e.key === "F9" || (e.ctrlKey && e.key === "Enter")) {
        e.preventDefault();
        if (cart.length > 0 && !overLimit) setShowPay(true);
      } else if (e.key === "F4") {
        e.preventDefault();
        setShowCustomer(true);
      } else if (e.key === "F8") {
        e.preventDefault();
        holdCart();
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  });

  // ---------------------------------------------------------------- complete
  const onCompleted = async (saleId: string) => {
    setShowPay(false);
    try {
      const data = await loadReceipt(saleId);
      setReceipt(data);
    } catch (e) {
      toast(errorMessage(e), "error");
    }
    // تحديث المخزون محلياً
    setCatalog((prev) =>
      prev.map((c) => {
        const line = cart.find((l) => l.item.variant_id === c.variant_id);
        return line ? { ...c, stock_qty: c.stock_qty - line.qty } : c;
      }),
    );
    setCart([]);
    setCustomer(null);
    setInvoiceDiscount("");
    setMobileCart(false);
    if (creditId) router.replace("/pos");
    setCredit(null);
  };

  const pickerProduct = products.find((p) => p.product_id === picker) ?? null;

  // ---------------------------------------------------------------- render
  const cartPanel = (
    <div className="flex h-full flex-col bg-white">
      <div className="flex items-center gap-2 border-b border-slate-100 p-3">
        <button
          onClick={() => setShowCustomer(true)}
          className="flex min-w-0 flex-1 items-center gap-2 rounded-lg border border-dashed border-slate-300 px-3 py-2 text-sm hover:border-brand-600 hover:bg-brand-50"
        >
          <UserRound className="size-4 shrink-0 text-slate-500" />
          <span className="truncate">{customer ? `${customer.name} ${customer.phone ?? ""}` : "عميل نقدي (F4)"}</span>
        </button>
        {customer && (
          <button onClick={() => setCustomer(null)} className="p-1 text-slate-400 hover:text-red-600" aria-label="إزالة العميل">
            <X className="size-4" />
          </button>
        )}
        <Button variant="outline" size="sm" onClick={() => setShowHeld(true)} title="الفواتير المعلقة">
          <PlayCircle className="size-4" />
          {held.length > 0 && <Badge tone="amber">{held.length}</Badge>}
        </Button>
      </div>

      {credit && (
        <div className="mx-3 mt-3 rounded-lg bg-violet-50 p-2.5 text-sm text-violet-800">
          استبدال: رصيد {money(credit.total)} من المرتجع {credit.return_no}
        </div>
      )}

      <div className="flex-1 overflow-y-auto scrollbar-thin">
        {cart.length === 0 ? (
          <div className="flex h-full flex-col items-center justify-center gap-2 p-6 text-center text-slate-400">
            <ShoppingBag className="size-12" />
            <p>امسح الباركود أو اختر منتجاً</p>
          </div>
        ) : (
          <ul className="divide-y divide-slate-100">
            {cart.map((l, idx) => (
              <li key={l.item.variant_id} className="p-3">
                <div className="flex items-start gap-2">
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-sm font-medium">{l.item.product_name}</p>
                    <p className="text-xs text-slate-500">
                      {variantLabel(l.item.size, l.item.color) || l.item.sku} · {money(l.item.price)}
                    </p>
                  </div>
                  <p className="text-sm font-semibold">{money(totals.lines[idx]?.lineTotal ?? 0)}</p>
                </div>
                <div className="mt-2 flex items-center gap-2">
                  <div className="flex items-center rounded-lg border border-slate-200">
                    <button className="p-1.5 hover:bg-slate-100" onClick={() => setQty(l.item.variant_id, l.qty - 1)} aria-label="إنقاص">
                      <Minus className="size-4" />
                    </button>
                    <input
                      className="w-10 bg-transparent text-center text-sm font-semibold outline-none"
                      inputMode="numeric"
                      value={l.qty}
                      onChange={(e) => setQty(l.item.variant_id, Number(e.target.value.replace(/\D/g, "")) || 0)}
                    />
                    <button className="p-1.5 hover:bg-slate-100" onClick={() => setQty(l.item.variant_id, l.qty + 1)} aria-label="زيادة">
                      <Plus className="size-4" />
                    </button>
                  </div>
                  {editLine === l.item.variant_id ? (
                    <Input
                      autoFocus
                      type="number"
                      min={0}
                      step="0.01"
                      className="h-8 w-24"
                      placeholder="خصم ر.س"
                      defaultValue={l.discount || ""}
                      onBlur={(e) => {
                        setLineDiscount(l.item.variant_id, Number(e.target.value) || 0);
                        setEditLine(null);
                      }}
                      onKeyDown={(e) => {
                        if (e.key === "Enter") (e.target as HTMLInputElement).blur();
                      }}
                    />
                  ) : (
                    <button
                      className="text-xs text-brand-700 hover:underline"
                      onClick={() => setEditLine(l.item.variant_id)}
                    >
                      {l.discount > 0 ? `خصم ${money(l.discount)}` : "+ خصم"}
                    </button>
                  )}
                  <button
                    className="ms-auto p-1.5 text-slate-400 hover:text-red-600"
                    onClick={() => setQty(l.item.variant_id, 0)}
                    aria-label="حذف"
                  >
                    <Trash2 className="size-4" />
                  </button>
                </div>
              </li>
            ))}
          </ul>
        )}
      </div>

      <div className="space-y-2 border-t border-slate-200 bg-slate-50 p-3 text-sm">
        <div className="flex items-center gap-2">
          <span className="text-slate-600">خصم الفاتورة</span>
          <Input
            type="number"
            min={0}
            step="0.01"
            className="h-8 flex-1"
            value={invoiceDiscount}
            onChange={(e) => setInvoiceDiscount(e.target.value)}
            placeholder="0"
          />
          <div className="flex overflow-hidden rounded-lg border border-slate-300 text-xs">
            {(["amount", "percent"] as const).map((m) => (
              <button
                key={m}
                onClick={() => setDiscountMode(m)}
                className={cn("px-2.5 py-1.5", discountMode === m ? "bg-slate-800 text-white" : "bg-white")}
              >
                {m === "amount" ? "ر.س" : "%"}
              </button>
            ))}
          </div>
        </div>
        <Row label={`المجموع (${itemsCount} قطعة)`} value={money(totals.gross)} />
        {totals.discountTotal > 0 && (
          <Row label={`الخصم (${discountPct.toFixed(1)}%)`} value={`- ${money(totals.discountTotal)}`} className="text-red-600" />
        )}
        <Row label="الإجمالي قبل الضريبة" value={money(totals.subtotal)} />
        <Row label={`ضريبة القيمة المضافة ${vatRate}%`} value={money(totals.vat)} />
        <div className="flex items-center justify-between border-t border-slate-200 pt-2 text-lg font-bold">
          <span>الإجمالي</span>
          <span>{money(totals.total)}</span>
        </div>
        {overLimit && (
          <p className="rounded bg-red-50 p-2 text-xs text-red-700">
            الخصم يتجاوز الحد المسموح للكاشير ({Number(settings.max_cashier_discount_pct)}%)
          </p>
        )}
        <div className="grid grid-cols-4 gap-2 pt-1">
          <Button variant="outline" size="lg" onClick={holdCart} disabled={cart.length === 0} title="تعليق (F8)">
            <PauseCircle className="size-5" />
          </Button>
          <Button
            variant="outline"
            size="lg"
            onClick={clearSale}
            disabled={cart.length === 0 && !credit}
            title="إلغاء"
            className="text-red-600"
          >
            <Trash2 className="size-5" />
          </Button>
          <Button size="lg" className="col-span-2" disabled={cart.length === 0 || overLimit} onClick={() => setShowPay(true)}>
            الدفع (F9)
          </Button>
        </div>
      </div>
    </div>
  );

  return (
    <div className="flex h-[calc(100dvh-3.5rem)] lg:h-dvh">
      {/* Products */}
      <section className="flex min-w-0 flex-1 flex-col">
        <div className="space-y-3 border-b border-slate-200 bg-white p-3">
          <div className="flex gap-2">
            <div className="relative flex-1">
              <ScanBarcode className="pointer-events-none absolute start-3 top-1/2 size-5 -translate-y-1/2 text-slate-400" />
              <Input
                ref={searchRef}
                autoFocus
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") {
                    e.preventDefault();
                    onSearchEnter();
                  } else if (e.key === "Escape") setQuery("");
                }}
                placeholder="امسح الباركود أو ابحث بالاسم / SKU  (F2)"
                className="h-12 ps-10 text-base"
              />
            </div>
            <Button variant="outline" size="lg" onClick={loadCatalog} title="تحديث" aria-label="تحديث">
              <RefreshCw className={cn("size-5", loading && "animate-spin")} />
            </Button>
          </div>
          <div className="flex gap-2 overflow-x-auto pb-1 scrollbar-thin">
            <Chip active={category === null} onClick={() => setCategory(null)}>
              الكل
            </Chip>
            {categories.map((c) => (
              <Chip key={c.id} active={category === c.id} onClick={() => setCategory(c.id)}>
                {c.name}
              </Chip>
            ))}
          </div>
        </div>

        <div className="flex-1 overflow-y-auto p-3 pb-24 scrollbar-thin lg:pb-3">
          {loading && catalog.length === 0 ? (
            <div className="py-20 text-center text-slate-500">جاري تحميل المنتجات...</div>
          ) : filtered.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-20 text-slate-500">
              <Search className="size-10" /> لا توجد منتجات مطابقة
            </div>
          ) : (
            <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 xl:grid-cols-4 2xl:grid-cols-5">
              {filtered.map((p) => {
                const stock = p.variants.reduce((s, v) => s + v.stock_qty, 0);
                const prices = p.variants.map((v) => v.price);
                const min = Math.min(...prices);
                const max = Math.max(...prices);
                return (
                  <button
                    key={p.product_id}
                    onClick={() => onProductClick(p.product_id)}
                    className="group flex flex-col overflow-hidden rounded-xl border border-slate-200 bg-white text-start shadow-sm transition hover:border-brand-600 hover:shadow-md active:scale-[0.98]"
                  >
                    <div className="relative aspect-square w-full bg-slate-100">
                      {p.image_url ? (
                        // eslint-disable-next-line @next/next/no-img-element
                        <img src={p.image_url} alt={p.name} className="size-full object-cover" loading="lazy" />
                      ) : (
                        <div className="flex size-full items-center justify-center text-3xl font-bold text-slate-300">
                          {p.name.slice(0, 2)}
                        </div>
                      )}
                      <span
                        className={cn(
                          "absolute start-2 top-2 rounded-full px-2 py-0.5 text-xs font-semibold",
                          stock <= 0 ? "bg-red-600 text-white" : "bg-white/90 text-slate-700",
                        )}
                      >
                        {stock <= 0 ? "نفد" : stock}
                      </span>
                    </div>
                    <div className="p-2.5">
                      <p className="line-clamp-2 text-sm font-medium leading-snug">{p.name}</p>
                      <p className="mt-1 text-sm font-bold text-brand-700">
                        {min === max ? money(min) : `${money(min)} - ${max.toFixed(2)}`}
                      </p>
                      {p.variants.length > 1 && <p className="text-xs text-slate-500">{p.variants.length} خيارات</p>}
                    </div>
                  </button>
                );
              })}
            </div>
          )}
        </div>
      </section>

      {/* Cart (desktop) */}
      <aside className="hidden w-[380px] shrink-0 border-s border-slate-200 lg:block xl:w-[420px]">{cartPanel}</aside>

      {/* Cart (mobile) */}
      <button
        onClick={() => setMobileCart(true)}
        className="no-print fixed inset-x-3 bottom-3 z-20 flex items-center justify-between rounded-xl bg-brand-700 px-4 py-3.5 text-white shadow-lg lg:hidden"
      >
        <span className="flex items-center gap-2">
          <ShoppingBag className="size-5" /> السلة ({itemsCount})
        </span>
        <span className="font-bold">{money(totals.total)}</span>
      </button>
      {mobileCart && (
        <div className="no-print fixed inset-0 z-40 flex flex-col bg-white lg:hidden">
          <div className="flex h-12 items-center justify-between border-b border-slate-200 px-3">
            <span className="font-semibold">السلة</span>
            <button onClick={() => setMobileCart(false)} className="p-1" aria-label="إغلاق">
              <X className="size-5" />
            </button>
          </div>
          <div className="min-h-0 flex-1">{cartPanel}</div>
        </div>
      )}

      {/* Variant picker */}
      <VariantPicker
        product={pickerProduct}
        onClose={() => {
          setPicker(null);
          focusSearch();
        }}
        onPick={(v) => {
          addToCart(v);
          setPicker(null);
          focusSearch();
        }}
        allowNegative={settings.allow_negative_stock}
      />

      <CustomerPicker
        open={showCustomer}
        onClose={() => {
          setShowCustomer(false);
          focusSearch();
        }}
        onPick={(c) => {
          setCustomer(c);
          setShowCustomer(false);
          focusSearch();
        }}
      />

      {showPay && (
        <PaymentModal
          total={totals.total}
          credit={credit}
          onClose={() => {
            setShowPay(false);
            focusSearch();
          }}
          onSubmit={async (payments) => {
            const { data, error } = await supabase().rpc("complete_sale", {
              p_items: cart.map((l) => ({ variant_id: l.item.variant_id, qty: l.qty, discount: l.discount })),
              p_payments: payments,
              p_customer_id: customer?.id ?? null,
              p_invoice_discount: totals.invoiceDiscount,
              p_notes: null,
            });
            if (error) throw error;
            await onCompleted(data as string);
          }}
        />
      )}

      <HeldCartsModal open={showHeld} held={held} onClose={() => setShowHeld(false)} onResume={resumeHeld} onDelete={(id) => {
        const list = held.filter((h) => h.id !== id);
        setHeld(list);
        writeHeld(list);
      }} />

      <ReceiptModal
        data={receipt}
        title="تمت عملية البيع بنجاح"
        onClose={() => {
          setReceipt(null);
          focusSearch();
        }}
        extraActions={
          <Button
            variant="secondary"
            onClick={() => {
              setReceipt(null);
              focusSearch();
            }}
          >
            عملية جديدة
          </Button>
        }
      />
    </div>
  );
}

function Row({ label, value, className }: { label: string; value: string; className?: string }) {
  return (
    <div className={cn("flex items-center justify-between text-slate-600", className)}>
      <span>{label}</span>
      <span className="font-medium">{value}</span>
    </div>
  );
}

function Chip({ active, onClick, children }: { active: boolean; onClick: () => void; children: React.ReactNode }) {
  return (
    <button
      onClick={onClick}
      className={cn(
        "shrink-0 rounded-full px-4 py-1.5 text-sm font-medium transition",
        active ? "bg-slate-900 text-white" : "bg-slate-100 text-slate-700 hover:bg-slate-200",
      )}
    >
      {children}
    </button>
  );
}

// ======================================================================
// Variant picker: sizes × colors grid
// ======================================================================
function VariantPicker({
  product,
  onClose,
  onPick,
  allowNegative,
}: {
  product: { name: string; image_url: string | null; variants: CatalogItem[] } | null;
  onClose: () => void;
  onPick: (v: CatalogItem) => void;
  allowNegative: boolean;
}) {
  if (!product) return null;
  const colors = [...new Set(product.variants.map((v) => v.color ?? ""))];
  return (
    <Modal open onClose={onClose} title={product.name} size="lg">
      <div className="space-y-4">
        {colors.map((color) => {
          const vs = product.variants.filter((v) => (v.color ?? "") === color);
          return (
            <div key={color}>
              {color && (
                <p className="mb-2 flex items-center gap-2 text-sm font-semibold text-slate-700">
                  {vs[0].color_hex && (
                    <span className="size-4 rounded-full border border-slate-300" style={{ background: vs[0].color_hex }} />
                  )}
                  {color}
                </p>
              )}
              <div className="grid grid-cols-3 gap-2 sm:grid-cols-5">
                {vs.map((v) => {
                  const out = v.stock_qty <= 0;
                  return (
                    <button
                      key={v.variant_id}
                      disabled={out && !allowNegative}
                      onClick={() => onPick(v)}
                      className={cn(
                        "rounded-lg border-2 p-2 text-center transition",
                        out ? "border-slate-200 bg-slate-50 text-slate-400" : "border-slate-200 hover:border-brand-600 hover:bg-brand-50",
                      )}
                    >
                      <div className="text-base font-bold">{v.size || "—"}</div>
                      <div className="text-xs">{out ? "نفد" : `متوفر ${v.stock_qty}`}</div>
                      <div className="text-xs font-medium text-brand-700">{v.price.toFixed(2)}</div>
                    </button>
                  );
                })}
              </div>
            </div>
          );
        })}
      </div>
    </Modal>
  );
}

// ======================================================================
// Customer picker with quick add
// ======================================================================
function CustomerPicker({ open, onClose, onPick }: { open: boolean; onClose: () => void; onPick: (c: Customer) => void }) {
  const toast = useToast();
  const [q, setQ] = useState("");
  const [results, setResults] = useState<Customer[]>([]);
  const [adding, setAdding] = useState(false);
  const [form, setForm] = useState({ name: "", phone: "", vat_number: "" });
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!open) return;
    const term = q.trim();
    const t = setTimeout(async () => {
      let req = supabase().from("customers").select("*").order("created_at", { ascending: false }).limit(20);
      if (term) req = req.or(`name.ilike.%${term.replace(/[%,()]/g, "")}%,phone.ilike.%${term.replace(/[%,()]/g, "")}%`);
      const { data } = await req;
      setResults((data ?? []) as Customer[]);
    }, 200);
    return () => clearTimeout(t);
  }, [q, open]);

  const save = async () => {
    if (!form.name.trim()) return;
    setSaving(true);
    const { data, error } = await supabase()
      .from("customers")
      .insert({ name: form.name.trim(), phone: form.phone.trim() || null, vat_number: form.vat_number.trim() || null })
      .select()
      .single();
    setSaving(false);
    if (error) {
      toast(errorMessage(error), "error");
      return;
    }
    setForm({ name: "", phone: "", vat_number: "" });
    setAdding(false);
    onPick(data as Customer);
  };

  return (
    <Modal open={open} onClose={onClose} title="اختيار العميل">
      {adding ? (
        <div className="space-y-3">
          <Field label="الاسم">
            <Input autoFocus value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
          </Field>
          <Field label="الجوال">
            <Input dir="ltr" inputMode="tel" placeholder="05xxxxxxxx" value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })} />
          </Field>
          <Field label="الرقم الضريبي (للشركات)">
            <Input dir="ltr" value={form.vat_number} onChange={(e) => setForm({ ...form, vat_number: e.target.value })} />
          </Field>
          <div className="flex justify-end gap-2">
            <Button variant="outline" onClick={() => setAdding(false)}>
              رجوع
            </Button>
            <Button onClick={save} loading={saving}>
              حفظ واختيار
            </Button>
          </div>
        </div>
      ) : (
        <div className="space-y-3">
          <div className="flex gap-2">
            <Input autoFocus placeholder="ابحث بالاسم أو الجوال" value={q} onChange={(e) => setQ(e.target.value)} />
            <Button
              variant="outline"
              onClick={() => {
                setAdding(true);
                setForm({ name: "", phone: /^\d+$/.test(q.trim()) ? q.trim() : "", vat_number: "" });
              }}
            >
              <UserPlus className="size-4" /> جديد
            </Button>
          </div>
          <ul className="max-h-80 divide-y divide-slate-100 overflow-y-auto">
            {results.map((c) => (
              <li key={c.id}>
                <button className="flex w-full items-center justify-between px-2 py-2.5 text-start hover:bg-slate-50" onClick={() => onPick(c)}>
                  <span className="font-medium">{c.name}</span>
                  <span className="ltr-nums text-sm text-slate-500">{c.phone}</span>
                </button>
              </li>
            ))}
            {results.length === 0 && <li className="py-6 text-center text-sm text-slate-500">لا توجد نتائج</li>}
          </ul>
        </div>
      )}
    </Modal>
  );
}

// ======================================================================
// Payment: cash / card / transfer / split + exchange credit
// ======================================================================
const METHOD_ICONS = { cash: Banknote, card: CreditCard, transfer: Landmark };

function PaymentModal({
  total,
  credit,
  onClose,
  onSubmit,
}: {
  total: number;
  credit: ReturnRecord | null;
  onClose: () => void;
  onSubmit: (payments: Array<Record<string, unknown>>) => Promise<void>;
}) {
  const toast = useToast();
  const creditAmount = credit ? Number(credit.total) : 0;
  const due = round2(Math.max(total - creditAmount, 0));
  const [rows, setRows] = useState<PaymentRow[]>([{ method: "cash", amount: due.toFixed(2), reference: "" }]);
  const [busy, setBusy] = useState(false);

  const paid = round2(rows.reduce((s, r) => s + (Number(r.amount) || 0), 0));
  const cashPaid = round2(rows.filter((r) => r.method === "cash").reduce((s, r) => s + (Number(r.amount) || 0), 0));
  const nonCash = round2(paid - cashPaid);
  const remaining = round2(due - paid);
  const change = round2(Math.max(paid - due, 0));
  const creditTooBig = creditAmount > total + 0.001;
  const invalid = remaining > 0.001 || nonCash > due + 0.001 || creditTooBig;

  const setRow = (i: number, patch: Partial<PaymentRow>) => setRows((r) => r.map((x, idx) => (idx === i ? { ...x, ...patch } : x)));

  const selectSingle = (method: PaymentRow["method"]) => setRows([{ method, amount: due.toFixed(2), reference: "" }]);

  const quickCash = [...new Set([due, Math.ceil(due / 10) * 10, Math.ceil(due / 50) * 50, Math.ceil(due / 100) * 100, Math.ceil(due / 500) * 500])]
    .filter((v) => v >= due)
    .slice(0, 5);

  const submit = async () => {
    if (invalid || busy) return;
    setBusy(true);
    try {
      const payments: Array<Record<string, unknown>> = rows
        .filter((r) => Number(r.amount) > 0)
        .map((r) => ({ method: r.method, amount: round2(Number(r.amount)), reference: r.reference || null }));
      if (credit) payments.unshift({ method: "exchange_credit", amount: creditAmount, return_id: credit.id });
      await onSubmit(payments);
    } catch (e) {
      toast(errorMessage(e), "error");
      setBusy(false);
    }
  };

  return (
    <Modal
      open
      onClose={busy ? () => {} : onClose}
      title="الدفع"
      size="md"
      footer={
        <Button size="xl" className="w-full" onClick={submit} disabled={invalid} loading={busy}>
          إتمام البيع {change > 0 ? `— الباقي ${money(change)}` : ""}
        </Button>
      }
    >
      <div
        className="space-y-4"
        onKeyDown={(e) => {
          if (e.key === "Enter" && !invalid) {
            e.preventDefault();
            submit();
          }
        }}
      >
        <div className="rounded-xl bg-slate-900 p-4 text-center text-white">
          <p className="text-sm text-slate-300">المطلوب</p>
          <p className="text-3xl font-bold">{money(due)}</p>
          {credit && (
            <p className="mt-1 text-xs text-violet-200">
              الإجمالي {money(total)} − رصيد الاستبدال {money(creditAmount)}
            </p>
          )}
        </div>
        {creditTooBig && (
          <p className="rounded bg-red-50 p-2 text-sm text-red-700">
            قيمة المرتجع أكبر من الفاتورة الجديدة — أضف أصنافاً أخرى أو استخدم الإرجاع النقدي.
          </p>
        )}

        <div className="grid grid-cols-3 gap-2">
          {(["cash", "card", "transfer"] as const).map((m) => {
            const Icon = METHOD_ICONS[m];
            const active = rows.length === 1 && rows[0].method === m;
            return (
              <button
                key={m}
                onClick={() => selectSingle(m)}
                className={cn(
                  "flex flex-col items-center gap-1 rounded-xl border-2 py-3 text-sm font-medium",
                  active ? "border-brand-700 bg-brand-50 text-brand-800" : "border-slate-200 hover:border-slate-300",
                )}
              >
                <Icon className="size-6" />
                {PAYMENT_LABELS[m]}
              </button>
            );
          })}
        </div>

        <div className="space-y-2">
          {rows.map((r, i) => (
            <div key={i} className="flex items-center gap-2">
              <select
                value={r.method}
                onChange={(e) => setRow(i, { method: e.target.value as PaymentRow["method"] })}
                className="h-11 rounded-lg border border-slate-300 px-2 text-sm"
              >
                <option value="cash">نقدي</option>
                <option value="card">شبكة</option>
                <option value="transfer">تحويل</option>
              </select>
              <Input
                type="number"
                inputMode="decimal"
                step="0.01"
                min={0}
                className="h-11 flex-1 text-lg font-semibold"
                value={r.amount}
                autoFocus={i === rows.length - 1}
                onFocus={(e) => e.target.select()}
                onChange={(e) => setRow(i, { amount: e.target.value })}
              />
              {r.method !== "cash" && (
                <Input
                  className="h-11 w-28"
                  placeholder="مرجع"
                  value={r.reference}
                  onChange={(e) => setRow(i, { reference: e.target.value })}
                />
              )}
              {rows.length > 1 && (
                <button className="p-2 text-slate-400 hover:text-red-600" onClick={() => setRows(rows.filter((_, idx) => idx !== i))} aria-label="حذف">
                  <X className="size-4" />
                </button>
              )}
            </div>
          ))}
          <button
            className="text-sm font-medium text-brand-700 hover:underline"
            onClick={() =>
              setRows([...rows, { method: rows[0]?.method === "cash" ? "card" : "cash", amount: Math.max(remaining, 0).toFixed(2), reference: "" }])
            }
          >
            + تقسيم الدفع
          </button>
        </div>

        {rows.length === 1 && rows[0].method === "cash" && due > 0 && (
          <div className="flex flex-wrap gap-2">
            {quickCash.map((v) => (
              <Button key={v} variant="outline" size="sm" onClick={() => setRow(0, { amount: v.toFixed(2) })}>
                {v.toFixed(0)}
              </Button>
            ))}
          </div>
        )}

        <div className="grid grid-cols-2 gap-3 text-center">
          <div className={cn("rounded-lg p-3", remaining > 0.001 ? "bg-red-50 text-red-700" : "bg-slate-50")}>
            <p className="text-xs">المتبقي</p>
            <p className="text-lg font-bold">{money(Math.max(remaining, 0))}</p>
          </div>
          <div className={cn("rounded-lg p-3", change > 0 ? "bg-emerald-50 text-emerald-700" : "bg-slate-50")}>
            <p className="text-xs">الباقي للعميل</p>
            <p className="text-lg font-bold">{money(change)}</p>
          </div>
        </div>
        {nonCash > due + 0.001 && <p className="text-sm text-red-600">مبلغ الشبكة/التحويل لا يمكن أن يتجاوز المطلوب</p>}
      </div>
    </Modal>
  );
}

function HeldCartsModal({
  open,
  held,
  onClose,
  onResume,
  onDelete,
}: {
  open: boolean;
  held: HeldCart[];
  onClose: () => void;
  onResume: (id: string) => void;
  onDelete: (id: string) => void;
}) {
  return (
    <Modal open={open} onClose={onClose} title="الفواتير المعلقة">
      {held.length === 0 ? (
        <p className="py-8 text-center text-sm text-slate-500">لا توجد فواتير معلقة</p>
      ) : (
        <ul className="divide-y divide-slate-100">
          {held.map((h) => (
            <li key={h.id} className="flex items-center gap-3 py-3">
              <div className="min-w-0 flex-1">
                <p className="font-medium">{h.label}</p>
                <p className="text-xs text-slate-500">
                  {h.lines.reduce((s, l) => s + l.qty, 0)} قطعة · {new Date(h.at).toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" })}
                </p>
              </div>
              <Button size="sm" onClick={() => onResume(h.id)}>
                استئناف
              </Button>
              <button className="p-1.5 text-slate-400 hover:text-red-600" onClick={() => onDelete(h.id)} aria-label="حذف">
                <Trash2 className="size-4" />
              </button>
            </li>
          ))}
        </ul>
      )}
    </Modal>
  );
}

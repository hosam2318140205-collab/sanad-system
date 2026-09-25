"use client";

import { Camera, CheckCircle2, X, XCircle } from "lucide-react";
import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { Button, cn } from "./ui";

export interface ScanOutcome {
  ok: boolean;
  message: string;
}

// A barcode in view is decoded several times per second. The same code counts again only
// after it has left the camera view for this long (e.g. moving to a second identical item),
// so holding the phone still over one label never adds it twice.
const OUT_OF_VIEW_MS = 800;

const subscribe = () => () => {};
function useCameraSupported() {
  return useSyncExternalStore(
    subscribe,
    () => typeof navigator !== "undefined" && !!navigator.mediaDevices?.getUserMedia,
    () => false,
  );
}

function feedback(ok: boolean) {
  try {
    navigator.vibrate?.(ok ? 60 : [40, 60, 40]);
  } catch {
    /* not supported */
  }
  try {
    const Ctx = window.AudioContext ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
    if (!Ctx) return;
    const ctx = new Ctx();
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.frequency.value = ok ? 1400 : 300;
    gain.gain.value = 0.08;
    osc.connect(gain).connect(ctx.destination);
    osc.start();
    osc.stop(ctx.currentTime + (ok ? 0.09 : 0.25));
    osc.onended = () => ctx.close();
  } catch {
    /* audio unavailable */
  }
}

function cameraError(err: unknown): string {
  const name = (err as { name?: string })?.name ?? "";
  if (name === "NotAllowedError" || name === "SecurityError")
    return "لم يُسمح باستخدام الكاميرا. اسمح للموقع باستخدامها من إعدادات المتصفح ثم أعد المحاولة.";
  if (name === "NotFoundError" || name === "OverconstrainedError") return "لا توجد كاميرا متاحة على هذا الجهاز.";
  if (name === "NotReadableError") return "الكاميرا مستخدمة من تطبيق آخر. أغلقه ثم أعد المحاولة.";
  if (typeof window !== "undefined" && !window.isSecureContext) return "الكاميرا تعمل فقط عبر رابط آمن (https).";
  return "تعذر تشغيل الكاميرا.";
}

/**
 * Full-screen camera barcode scanner.
 * `continuous`: stays open for the next item (POS, stock counts); otherwise closes after the first read.
 * `onDetected` may return an outcome to show under the viewfinder.
 */
export function CameraScanner({
  open,
  onClose,
  onDetected,
  continuous = false,
  title = "مسح الباركود بالكاميرا",
  withQr = false,
}: {
  open: boolean;
  onClose: () => void;
  onDetected: (code: string) => ScanOutcome | void;
  continuous?: boolean;
  title?: string;
  /** قراءة رموز QR أيضاً (مثل رمز الفاتورة في المرتجع) */
  withQr?: boolean;
}) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const handlerRef = useRef(onDetected);
  const withQrRef = useRef(withQr);
  const closeRef = useRef(onClose);
  const [error, setError] = useState<string | null>(null);
  const [starting, setStarting] = useState(true);
  const [last, setLast] = useState<ScanOutcome | null>(null);

  useEffect(() => {
    handlerRef.current = onDetected;
    closeRef.current = onClose;
  });

  useEffect(() => {
    if (!open) return;
    let stopped = false;
    let controls: { stop: () => void } | null = null;
    let lastCode = "";
    let lastSeen = 0;

    (async () => {
      try {
        const [{ BrowserMultiFormatReader }, { BarcodeFormat, DecodeHintType }] = await Promise.all([
          import("@zxing/browser"),
          import("@zxing/library"),
        ]);
        const hints = new Map();
        hints.set(DecodeHintType.POSSIBLE_FORMATS, [
          BarcodeFormat.EAN_13,
          BarcodeFormat.EAN_8,
          BarcodeFormat.UPC_A,
          BarcodeFormat.UPC_E,
          BarcodeFormat.CODE_128,
          BarcodeFormat.CODE_39,
          ...(withQrRef.current ? [BarcodeFormat.QR_CODE] : []),
        ]);
        const reader = new BrowserMultiFormatReader(hints, { delayBetweenScanAttempts: 120 });
        if (stopped || !videoRef.current) return;
        const c = await reader.decodeFromConstraints(
          { video: { facingMode: { ideal: "environment" }, width: { ideal: 1280 }, height: { ideal: 720 } }, audio: false },
          videoRef.current,
          (result, _err, liveControls) => {
            if (!result || stopped) return;
            const code = result.getText().trim();
            const now = Date.now();
            if (code === lastCode && now - lastSeen < OUT_OF_VIEW_MS) {
              lastSeen = now; // still in view: keep ignoring
              return;
            }
            lastCode = code;
            lastSeen = now;
            const outcome = handlerRef.current(code) ?? { ok: true, message: code };
            feedback(outcome.ok);
            setLast(outcome);
            if (!continuous && outcome.ok) {
              stopped = true;
              liveControls.stop();
              closeRef.current();
            }
          },
        );
        if (stopped) c.stop();
        else controls = c;
        setStarting(false);
      } catch (err) {
        if (!stopped) {
          setError(cameraError(err));
          setStarting(false);
        }
      }
    })();

    return () => {
      stopped = true;
      controls?.stop();
      setError(null);
      setStarting(true);
      setLast(null);
    };
  }, [open, continuous]);

  if (!open) return null;
  return (
    <div className="no-print fixed inset-0 z-[70] flex flex-col bg-black" role="dialog" aria-modal="true" aria-label={title}>
      <div className="flex items-center justify-between px-4 py-3 text-white" style={{ paddingTop: "calc(0.75rem + env(safe-area-inset-top, 0px))" }}>
        <span className="font-semibold">{title}</span>
        <button onClick={onClose} className="rounded-full bg-white/15 p-2" aria-label="إغلاق">
          <X className="size-5" />
        </button>
      </div>

      <div className="relative min-h-0 flex-1 overflow-hidden">
        <video ref={videoRef} className="absolute inset-0 size-full object-cover" muted playsInline autoPlay />
        {!error && (
          <div className="pointer-events-none absolute inset-0 flex items-center justify-center">
            <div className="relative h-40 w-[80%] max-w-md rounded-2xl border-2 border-white/90 shadow-[0_0_0_9999px_rgba(0,0,0,0.45)]">
              <div className="absolute inset-x-4 top-1/2 h-0.5 -translate-y-1/2 bg-red-500/80" />
            </div>
          </div>
        )}
        {starting && !error && <p className="absolute inset-x-0 top-6 text-center text-sm text-white/80">جاري تشغيل الكاميرا...</p>}
        {error && (
          <div className="absolute inset-0 flex flex-col items-center justify-center gap-4 p-6 text-center text-white">
            <Camera className="size-10 text-white/60" />
            <p>{error}</p>
            <Button variant="secondary" onClick={onClose}>
              إغلاق
            </Button>
          </div>
        )}
      </div>

      <div className="px-4 py-4 text-center" style={{ paddingBottom: "calc(1rem + env(safe-area-inset-bottom, 0px))" }}>
        {last ? (
          <p className={cn("inline-flex items-center gap-2 rounded-full px-4 py-2 text-sm font-medium", last.ok ? "bg-emerald-600 text-white" : "bg-red-600 text-white")}>
            {last.ok ? <CheckCircle2 className="size-4" /> : <XCircle className="size-4" />}
            {last.message}
          </p>
        ) : (
          <p className="text-sm text-white/70">وجّه الكاميرا إلى الباركود داخل الإطار</p>
        )}
        {continuous && <p className="mt-2 text-xs text-white/50">الكاميرا تبقى مفتوحة للقطعة التالية — اضغط إغلاق عند الانتهاء</p>}
      </div>
    </div>
  );
}

/** Camera button that only renders where the browser can open a camera. */
export function CameraScanButton({
  onClick,
  className,
  label = "مسح بالكاميرا",
  size = "lg",
}: {
  onClick: () => void;
  className?: string;
  label?: string;
  size?: "sm" | "md" | "lg";
}) {
  const supported = useCameraSupported();
  if (!supported) return null;
  return (
    <Button type="button" variant="outline" size={size} onClick={onClick} className={className} title={label} aria-label={label}>
      <Camera className="size-5" />
    </Button>
  );
}

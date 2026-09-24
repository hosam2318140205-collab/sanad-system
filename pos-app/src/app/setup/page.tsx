export default function SetupPage() {
  return (
    <div className="flex min-h-dvh items-center justify-center p-4">
      <div className="max-w-xl space-y-4 rounded-2xl bg-white p-8 shadow">
        <h1 className="text-2xl font-bold">إعداد النظام</h1>
        <p className="text-slate-600">لم يتم ربط التطبيق بقاعدة بيانات Supabase بعد. اتبع الخطوات:</p>
        <ol className="list-decimal space-y-2 pe-5 text-sm text-slate-700">
          <li>أنشئ مشروعاً جديداً على supabase.com.</li>
          <li>
            نفّذ ملفات <code className="rounded bg-slate-100 px-1">supabase/migrations</code> بالترتيب في SQL Editor
            (أو <code className="rounded bg-slate-100 px-1">supabase db push</code>).
          </li>
          <li>
            انسخ <code className="rounded bg-slate-100 px-1">.env.example</code> إلى{" "}
            <code className="rounded bg-slate-100 px-1">.env.local</code> وضع رابط المشروع والمفاتيح.
          </li>
          <li>أعد تشغيل التطبيق، ثم أنشئ أول مستخدم من لوحة Supabase — أول مستخدم يصبح المالك تلقائياً.</li>
        </ol>
      </div>
    </div>
  );
}

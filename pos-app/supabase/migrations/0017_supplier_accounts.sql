-- =====================================================================
-- 0017 حسابات الموردين (PR #9 — المرحلة 1)
--   • مستندات مستحقة (supplier_invoices): رصيد افتتاحي / فاتورة شراء / فاتورة مصروف (شحن، جمارك…)
--     هنا الرأس المالي فقط؛ بنود الشراء والمطابقة الثلاثية في 0018
--   • دفعات الموردين (نقد/درج الوردية/تحويل/شبكة/شيك) وتوزيعها على الفواتير؛ غير الموزّع = دفعة مقدمة
--   • دفتر المورد: إلحاق فقط، قيد واحد لكل مستند (unique entry_type + source_id)، ورصيد مجمّع يُطابق الدفتر
--     الرصيد = ما علينا للمورد (دائن يزيده، مدين ينقصه). السالب = دفعة مقدمة لدى المورد
--   • كشف حساب برصيد تراكمي، وأعمار الديون حسب الاستحقاق
--   • كل الكتابة عبر دوال بصلاحية ومفتاح منع تكرار؛ لا كتابة مباشرة على الجداول المالية
--   • لا يغيّر أي جدول قائم سوى أعمدة إضافية في suppliers (الكتابة القديمة على الموردين وأوامر الشراء تبقى كما هي)
-- =====================================================================

create type public.ap_entry_type as enum (
  'opening', 'invoice', 'payment', 'credit_note', 'refund', 'void_invoice', 'void_payment', 'void_credit_note');
create type public.ap_invoice_kind as enum ('opening', 'purchase', 'expense');
create type public.ap_invoice_status as enum ('draft', 'posted', 'partially_paid', 'paid', 'void');
create type public.ap_payment_terms as enum ('cash', 'credit', 'partial');
create type public.ap_payment_method as enum ('cash_drawer', 'cash', 'bank_transfer', 'card', 'cheque', 'opening');

-- ---------------------------------------------------------------------
-- بيانات المورد الإضافية
-- ---------------------------------------------------------------------
alter table public.suppliers
  add column code text,
  add column payment_terms_days integer not null default 0 check (payment_terms_days between 0 and 365),
  add column credit_limit numeric(12,2) check (credit_limit is null or credit_limit >= 0),
  add column iban text,
  add column vat_registered boolean not null default true,
  add column lead_time_days integer check (lead_time_days is null or lead_time_days between 0 and 365);
create unique index suppliers_code_key on public.suppliers (upper(code)) where code is not null;

-- ---------------------------------------------------------------------
-- المستندات المستحقة
-- ---------------------------------------------------------------------
create sequence public.supplier_invoice_seq start 1;
create sequence public.supplier_payment_seq start 1;

create table public.supplier_invoices (
  id uuid primary key default gen_random_uuid(),
  doc_no text not null unique
    default 'SIN-' || to_char(now() at time zone 'Asia/Riyadh', 'YY') || lpad(nextval('public.supplier_invoice_seq')::text, 5, '0'),
  supplier_id uuid not null references public.suppliers (id),
  kind public.ap_invoice_kind not null default 'purchase',
  status public.ap_invoice_status not null default 'draft',
  supplier_invoice_no text,
  invoice_date date not null default (now() at time zone 'Asia/Riyadh')::date,
  due_date date,
  payment_terms public.ap_payment_terms not null default 'credit',
  subtotal numeric(12,2) not null default 0 check (subtotal >= 0),
  vat_amount numeric(12,2) not null default 0 check (vat_amount >= 0),
  total numeric(12,2) not null default 0 check (total >= 0),
  settled_amount numeric(12,2) not null default 0 check (settled_amount >= 0),   -- من التوزيعات فقط
  notes text,
  client_ref uuid unique,
  created_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now(),
  posted_by uuid references public.profiles (id),
  posted_at timestamptz,
  voided_by uuid references public.profiles (id),
  voided_at timestamptz,
  void_reason text,
  updated_at timestamptz not null default now(),
  constraint supplier_invoice_settled_le_total check (settled_amount <= total)
);
create index supplier_invoices_supplier_idx on public.supplier_invoices (supplier_id, status, due_date);
-- رقم فاتورة المورد لا يتكرر لنفس المورد (بعد إزالة المسافات وتوحيد الحروف)، إلا بعد إلغاء الأولى
create unique index supplier_invoices_no_key on public.supplier_invoices
  (supplier_id, lower(regexp_replace(supplier_invoice_no, '\s', '', 'g')))
  where supplier_invoice_no is not null and status <> 'void';

create table public.supplier_payments (
  id uuid primary key default gen_random_uuid(),
  payment_no text not null unique
    default 'SPY-' || to_char(now() at time zone 'Asia/Riyadh', 'YY') || lpad(nextval('public.supplier_payment_seq')::text, 5, '0'),
  supplier_id uuid not null references public.suppliers (id),
  amount numeric(12,2) not null check (amount > 0),
  method public.ap_payment_method not null,
  reference text,
  paid_at date not null default (now() at time zone 'Asia/Riyadh')::date,
  shift_id uuid references public.shifts (id),
  shift_movement_id uuid references public.shift_cash_movements (id),
  allocated_amount numeric(12,2) not null default 0 check (allocated_amount >= 0),
  notes text,
  client_ref uuid unique,
  is_void boolean not null default false,
  void_reason text,
  voided_by uuid references public.profiles (id),
  voided_at timestamptz,
  created_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now(),
  constraint supplier_payment_alloc_le_amount check (allocated_amount <= amount)
);
create index supplier_payments_supplier_idx on public.supplier_payments (supplier_id, paid_at);

-- توزيع الدفعات (والإشعارات الدائنة في 0019) على الفواتير. الإلغاء يعلّم التوزيع ولا يحذفه
create table public.supplier_allocations (
  id bigint generated always as identity primary key,
  supplier_id uuid not null references public.suppliers (id),
  source_type text not null check (source_type in ('payment', 'credit_note')),
  source_id uuid not null,
  invoice_id uuid not null references public.supplier_invoices (id),
  amount numeric(12,2) not null check (amount > 0),
  created_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now(),
  voided_at timestamptz
);
create index supplier_allocations_invoice_idx on public.supplier_allocations (invoice_id) where voided_at is null;
create index supplier_allocations_source_idx on public.supplier_allocations (source_type, source_id) where voided_at is null;

-- ---------------------------------------------------------------------
-- الدفتر والرصيد
-- ---------------------------------------------------------------------
create table public.supplier_ledger (
  id bigint generated always as identity primary key,
  supplier_id uuid not null references public.suppliers (id) on delete restrict,
  entry_type public.ap_entry_type not null,
  source_id uuid not null,
  ref_no text,
  entry_date date not null default (now() at time zone 'Asia/Riyadh')::date,
  debit numeric(12,2) not null default 0 check (debit >= 0),     -- ينقص ما علينا (دفعة، إشعار دائن)
  credit numeric(12,2) not null default 0 check (credit >= 0),   -- يزيد ما علينا (فاتورة، رصيد افتتاحي)
  balance_after numeric(12,2) not null,
  note text,
  created_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default clock_timestamp(),
  constraint supplier_ledger_one_side check ((debit > 0) <> (credit > 0)),
  constraint supplier_ledger_unique_source unique (entry_type, source_id)
);
create index supplier_ledger_supplier_idx on public.supplier_ledger (supplier_id, id);

create table public.supplier_balances (
  supplier_id uuid primary key references public.suppliers (id) on delete restrict,
  balance numeric(12,2) not null default 0,
  updated_at timestamptz not null default now()
);

create trigger supplier_invoices_touch before update on public.supplier_invoices
  for each row execute function public.touch_updated_at();

-- قيد يُفحص عند نهاية المعاملة: الرصيد = الدفتر، والمسدَّد = التوزيعات، والموزَّع من الدفعة = توزيعاتها
create or replace function public._check_supplier_integrity(p_supplier uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_bal numeric;
  v_led numeric;
  r record;
begin
  select coalesce((select balance from public.supplier_balances where supplier_id = p_supplier), 0) into v_bal;
  select coalesce(sum(credit - debit), 0) into v_led from public.supplier_ledger where supplier_id = p_supplier;
  if v_bal <> v_led then
    raise exception 'تعارض حساب المورد: الرصيد % والدفتر %', v_bal, v_led;
  end if;
  for r in
    select i.doc_no, i.settled_amount,
           coalesce((select sum(a.amount) from public.supplier_allocations a where a.invoice_id = i.id and a.voided_at is null), 0) as alloc
      from public.supplier_invoices i where i.supplier_id = p_supplier
  loop
    if r.settled_amount <> r.alloc then
      raise exception 'تعارض المسدَّد للفاتورة %: % مقابل توزيعات %', r.doc_no, r.settled_amount, r.alloc;
    end if;
  end loop;
  for r in
    select p.payment_no, p.allocated_amount,
           coalesce((select sum(a.amount) from public.supplier_allocations a
                      where a.source_type = 'payment' and a.source_id = p.id and a.voided_at is null), 0) as alloc
      from public.supplier_payments p where p.supplier_id = p_supplier
  loop
    if r.allocated_amount <> r.alloc then
      raise exception 'تعارض توزيع الدفعة %: % مقابل %', r.payment_no, r.allocated_amount, r.alloc;
    end if;
  end loop;
end;
$$;

create or replace function public.supplier_integrity_trigger()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public._check_supplier_integrity(coalesce(new.supplier_id, old.supplier_id));
  return null;
end;
$$;
create constraint trigger supplier_ledger_integrity after insert on public.supplier_ledger
  deferrable initially deferred for each row execute function public.supplier_integrity_trigger();
create constraint trigger supplier_balances_integrity after insert or update on public.supplier_balances
  deferrable initially deferred for each row execute function public.supplier_integrity_trigger();
create constraint trigger supplier_allocations_integrity after insert or update on public.supplier_allocations
  deferrable initially deferred for each row execute function public.supplier_integrity_trigger();
create constraint trigger supplier_invoices_integrity after update of settled_amount on public.supplier_invoices
  deferrable initially deferred for each row execute function public.supplier_integrity_trigger();
create constraint trigger supplier_payments_integrity after update of allocated_amount on public.supplier_payments
  deferrable initially deferred for each row execute function public.supplier_integrity_trigger();

-- قيد في الدفتر + تحديث الرصيد (داخلي). قفل صف الرصيد يرتّب القيود المتزامنة لنفس المورد
create or replace function public._ap_post(
  p_supplier uuid, p_type public.ap_entry_type, p_source uuid, p_ref text,
  p_debit numeric, p_credit numeric, p_note text default null, p_date date default null
) returns numeric
language plpgsql security definer set search_path = public as $$
declare
  v_bal numeric;
begin
  insert into public.supplier_balances (supplier_id) values (p_supplier) on conflict (supplier_id) do nothing;
  select balance into v_bal from public.supplier_balances where supplier_id = p_supplier for update;
  v_bal := v_bal + coalesce(p_credit, 0) - coalesce(p_debit, 0);
  insert into public.supplier_ledger (supplier_id, entry_type, source_id, ref_no, entry_date, debit, credit, balance_after, note)
  values (p_supplier, p_type, p_source, p_ref, coalesce(p_date, (now() at time zone 'Asia/Riyadh')::date),
          coalesce(p_debit, 0), coalesce(p_credit, 0), v_bal, p_note);
  update public.supplier_balances set balance = v_bal, updated_at = now() where supplier_id = p_supplier;
  return v_bal;
end;
$$;

-- قفل المورد: كل عملية مالية على مورد تبدأ به (ترتيب أقفال ثابت: المورد ثم المستند)
create or replace function public._lock_supplier(p_supplier uuid)
returns public.suppliers language plpgsql security definer set search_path = public as $$
declare
  s public.suppliers;
begin
  select * into s from public.suppliers where id = p_supplier for update;
  if s.id is null then
    raise exception 'المورد غير موجود';
  end if;
  return s;
end;
$$;

create or replace function public._invoice_refresh_status(p_id uuid)
returns public.ap_invoice_status language plpgsql security definer set search_path = public as $$
declare
  i public.supplier_invoices;
  v public.ap_invoice_status;
begin
  select * into i from public.supplier_invoices where id = p_id;
  if i.status in ('draft', 'void') then
    return i.status;
  end if;
  v := case when i.settled_amount >= i.total then 'paid'
            when i.settled_amount > 0 then 'partially_paid' else 'posted' end;
  update public.supplier_invoices set status = v where id = p_id and status <> v;
  return v;
end;
$$;

-- توزيع مبلغ من مصدر (دفعة/إشعار دائن) على الفواتير المفتوحة: صريح أو الأقدم استحقاقاً أولاً
create or replace function public._ap_allocate(
  p_supplier uuid, p_source_type text, p_source uuid, p_available numeric, p_allocations jsonb
) returns numeric
language plpgsql security definer set search_path = public as $$
declare
  v_left numeric := p_available;
  v_used numeric := 0;
  v_amt numeric;
  r record;
begin
  if p_available <= 0 then
    return 0;
  end if;
  if p_allocations is not null and jsonb_typeof(p_allocations) = 'array' and jsonb_array_length(p_allocations) > 0 then
    for r in
      select (e ->> 'invoice_id')::uuid as invoice_id, sum((e ->> 'amount')::numeric) as amount
        from jsonb_array_elements(p_allocations) e group by 1
    loop
      if r.amount is null or r.amount <= 0 then
        raise exception 'مبلغ توزيع غير صحيح';
      end if;
      perform 1 from public.supplier_invoices
        where id = r.invoice_id and supplier_id = p_supplier and status in ('posted', 'partially_paid') for update;
      if not found then
        raise exception 'الفاتورة غير موجودة أو غير مفتوحة لهذا المورد';
      end if;
      if r.amount > (select total - settled_amount from public.supplier_invoices where id = r.invoice_id) then
        raise exception 'التوزيع أكبر من المتبقي على الفاتورة %', (select doc_no from public.supplier_invoices where id = r.invoice_id);
      end if;
      if r.amount > v_left then
        raise exception 'مجموع التوزيع أكبر من المبلغ المتاح (%)', p_available;
      end if;
      insert into public.supplier_allocations (supplier_id, source_type, source_id, invoice_id, amount)
      values (p_supplier, p_source_type, p_source, r.invoice_id, r.amount);
      update public.supplier_invoices set settled_amount = settled_amount + r.amount where id = r.invoice_id;
      perform public._invoice_refresh_status(r.invoice_id);
      v_left := v_left - r.amount;
      v_used := v_used + r.amount;
    end loop;
    return v_used;
  end if;

  for r in
    select id, total - settled_amount as open_amt from public.supplier_invoices
     where supplier_id = p_supplier and status in ('posted', 'partially_paid') and total > settled_amount
     order by coalesce(due_date, invoice_date), invoice_date, created_at
     for update
  loop
    exit when v_left <= 0;
    v_amt := least(v_left, r.open_amt);
    insert into public.supplier_allocations (supplier_id, source_type, source_id, invoice_id, amount)
    values (p_supplier, p_source_type, p_source, r.id, v_amt);
    update public.supplier_invoices set settled_amount = settled_amount + v_amt where id = r.id;
    perform public._invoice_refresh_status(r.id);
    v_left := v_left - v_amt;
    v_used := v_used + v_amt;
  end loop;
  return v_used;
end;
$$;

-- ---------------------------------------------------------------------
-- الرصيد الافتتاحي (للمالك، مرة واحدة لكل مورد)
--   موجب: فاتورة افتتاحية مستحقة. سالب: دفعة مقدمة افتتاحية لدى المورد
-- ---------------------------------------------------------------------
create or replace function public.set_supplier_opening_balance(
  p_supplier uuid, p_amount numeric, p_as_of date, p_reason text, p_client_ref uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  s public.suppliers;
  v_id uuid;
begin
  if not public.has_role('owner') then
    raise exception 'غير مصرح';
  end if;
  if coalesce(p_amount, 0) = 0 or coalesce(trim(p_reason), '') = '' then
    raise exception 'أدخل المبلغ والسبب';
  end if;
  s := public._lock_supplier(p_supplier);
  if p_client_ref is not null then
    select id into v_id from public.supplier_invoices where client_ref = p_client_ref;
    if v_id is null then
      select id into v_id from public.supplier_payments where client_ref = p_client_ref;
    end if;
    if v_id is not null then
      return v_id;
    end if;
  end if;
  if exists (select 1 from public.supplier_ledger where supplier_id = p_supplier and entry_type = 'opening') then
    raise exception 'الرصيد الافتتاحي لهذا المورد مسجّل مسبقاً';
  end if;

  if p_amount > 0 then
    insert into public.supplier_invoices (supplier_id, kind, status, invoice_date, due_date, payment_terms,
                                          subtotal, total, notes, client_ref, posted_by, posted_at)
    values (p_supplier, 'opening', 'posted', coalesce(p_as_of, current_date), coalesce(p_as_of, current_date), 'credit',
            p_amount, p_amount, trim(p_reason), p_client_ref, auth.uid(), now())
    returning id into v_id;
    perform public._ap_post(p_supplier, 'opening', v_id, 'رصيد افتتاحي', 0, p_amount, trim(p_reason), coalesce(p_as_of, current_date));
  else
    insert into public.supplier_payments (supplier_id, amount, method, paid_at, notes, client_ref)
    values (p_supplier, -p_amount, 'opening', coalesce(p_as_of, current_date), trim(p_reason), p_client_ref)
    returning id into v_id;
    perform public._ap_post(p_supplier, 'opening', v_id, 'رصيد افتتاحي (مقدّم)', -p_amount, 0, trim(p_reason), coalesce(p_as_of, current_date));
  end if;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- دفعة للمورد. درج الوردية للمالك/المدير فقط ومن ورديته المفتوحة
--   p_allocations: [{invoice_id, amount}] أو null = الأقدم استحقاقاً أولاً. المتبقي = دفعة مقدمة
-- ---------------------------------------------------------------------
create or replace function public.post_supplier_payment(
  p_supplier uuid, p_amount numeric, p_method public.ap_payment_method, p_reference text default null,
  p_paid_at date default null, p_allocations jsonb default null, p_notes text default null, p_client_ref uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  s public.suppliers;
  v_id uuid;
  v_no text;
  v_shift uuid;
  v_mv uuid;
  v_used numeric;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if coalesce(p_amount, 0) <= 0 then
    raise exception 'مبلغ غير صحيح';
  end if;
  if p_method = 'opening' then
    raise exception 'طريقة دفع غير صالحة';
  end if;
  if p_client_ref is not null then
    -- الضغطة الثانية بنفس المفتاح تنتظر الأولى ثم تعيد نفس الدفعة
    perform pg_advisory_xact_lock(hashtextextended('sp:' || p_client_ref::text, 0));
    select id into v_id from public.supplier_payments where client_ref = p_client_ref;
    if v_id is not null then
      return v_id;
    end if;
  end if;
  s := public._lock_supplier(p_supplier);
  if not s.is_active then
    raise exception 'المورد غير نشط';
  end if;
  if p_method in ('bank_transfer', 'cheque') and coalesce(trim(p_reference), '') = '' then
    raise exception 'أدخل رقم الحوالة أو الشيك';
  end if;

  insert into public.supplier_payments (supplier_id, amount, method, reference, paid_at, notes, client_ref)
  values (p_supplier, p_amount, p_method, nullif(trim(p_reference), ''), coalesce(p_paid_at, (now() at time zone 'Asia/Riyadh')::date),
          nullif(trim(p_notes), ''), p_client_ref)
  returning id, payment_no into v_id, v_no;

  if p_method = 'cash_drawer' then
    -- قفل الوردية: لا يُسحب من درج وردية أثناء إغلاقها
    select id into v_shift from public.shifts where cashier_id = auth.uid() and status = 'open' for update;
    if v_shift is null then
      raise exception 'لا توجد لديك وردية مفتوحة للدفع من الدرج — افتح وردية أو اختر طريقة دفع أخرى';
    end if;
    insert into public.shift_cash_movements (shift_id, type, amount, reason)
    values (v_shift, 'out', p_amount, 'دفعة مورد ' || v_no || ': ' || s.name)
    returning id into v_mv;
    update public.supplier_payments set shift_id = v_shift, shift_movement_id = v_mv where id = v_id;
  end if;

  perform public._ap_post(p_supplier, 'payment', v_id, v_no, p_amount, 0, nullif(trim(p_notes), ''),
                          coalesce(p_paid_at, (now() at time zone 'Asia/Riyadh')::date));
  v_used := public._ap_allocate(p_supplier, 'payment', v_id, p_amount, p_allocations);
  update public.supplier_payments set allocated_amount = v_used where id = v_id;
  return v_id;
end;
$$;

-- تطبيق رصيد غير موزّع (دفعة مقدمة، أو إشعار دائن في 0019) على فواتير
create or replace function public.allocate_supplier_credit(
  p_source_type text, p_source uuid, p_allocations jsonb default null
) returns numeric
language plpgsql security definer set search_path = public as $$
declare
  v_supplier uuid;
  v_free numeric;
  v_used numeric;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if p_source_type = 'payment' then
    select supplier_id into v_supplier from public.supplier_payments where id = p_source and not is_void;
  elsif p_source_type = 'credit_note' and to_regclass('public.supplier_credit_notes') is not null then
    execute 'select supplier_id from public.supplier_credit_notes where id = $1 and status = ''posted''' into v_supplier using p_source;
  end if;
  if v_supplier is null then
    raise exception 'المصدر غير موجود أو ملغي';
  end if;
  perform public._lock_supplier(v_supplier);
  if p_source_type = 'payment' then
    select amount - allocated_amount into v_free from public.supplier_payments where id = p_source for update;
  else
    execute 'select total - allocated_amount from public.supplier_credit_notes where id = $1 for update' into v_free using p_source;
  end if;
  if v_free <= 0 then
    raise exception 'لا يوجد رصيد غير موزّع';
  end if;
  v_used := public._ap_allocate(v_supplier, p_source_type, p_source, v_free, p_allocations);
  if v_used = 0 then
    raise exception 'لا توجد فواتير مفتوحة للتوزيع عليها';
  end if;
  if p_source_type = 'payment' then
    update public.supplier_payments set allocated_amount = allocated_amount + v_used where id = p_source;
  else
    execute 'update public.supplier_credit_notes set allocated_amount = allocated_amount + $2 where id = $1' using p_source, v_used;
  end if;
  return v_used;
end;
$$;

-- إلغاء دفعة: قيد عكسي، وتحرير توزيعاتها. دفعة الدرج تُلغى فقط ووردية الدفع ما زالت مفتوحة (ويعود المبلغ للدرج)
create or replace function public.void_supplier_payment(p_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  p public.supplier_payments;
  r record;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'السبب مطلوب';
  end if;
  select * into p from public.supplier_payments where id = p_id;
  if p.id is null then
    raise exception 'الدفعة غير موجودة';
  end if;
  perform public._lock_supplier(p.supplier_id);
  select * into p from public.supplier_payments where id = p_id for update;
  if p.is_void then
    raise exception 'الدفعة ملغاة مسبقاً';
  end if;
  if p.method = 'opening' then
    raise exception 'لا يُلغى الرصيد الافتتاحي';
  end if;
  if p.method = 'cash_drawer' then
    if (select status from public.shifts where id = p.shift_id for update) <> 'open' then
      raise exception 'وردية الدفع مغلقة — لا يمكن إلغاء دفعة من درجها (سجّل استرداداً بدلاً من ذلك)';
    end if;
    insert into public.shift_cash_movements (shift_id, type, amount, reason)
    values (p.shift_id, 'in', p.amount, 'إلغاء دفعة مورد ' || p.payment_no);
  end if;

  for r in select * from public.supplier_allocations where source_type = 'payment' and source_id = p_id and voided_at is null for update loop
    update public.supplier_allocations set voided_at = now() where id = r.id;
    update public.supplier_invoices set settled_amount = settled_amount - r.amount where id = r.invoice_id;
    perform public._invoice_refresh_status(r.invoice_id);
  end loop;
  update public.supplier_payments
     set is_void = true, allocated_amount = 0, void_reason = trim(p_reason), voided_by = auth.uid(), voided_at = now()
   where id = p_id;
  perform public._ap_post(p.supplier_id, 'void_payment', p_id, p.payment_no, 0, p.amount, 'إلغاء: ' || trim(p_reason));
end;
$$;

-- ---------------------------------------------------------------------
-- القراءة: الكشف، الأعمار، المستندات المفتوحة
-- ---------------------------------------------------------------------
create or replace function public.supplier_statement(p_supplier uuid, p_from date default null, p_to date default null)
returns table (entry_id bigint, entry_date date, entry_type public.ap_entry_type, ref_no text, note text,
               debit numeric, credit numeric, balance numeric, source_id uuid)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare
  v_open numeric;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  select coalesce(sum(l.credit - l.debit), 0) into v_open
    from public.supplier_ledger l where l.supplier_id = p_supplier and p_from is not null and l.entry_date < p_from;
  return query
    select null::bigint, coalesce(p_from, date '1900-01-01'), null::public.ap_entry_type, 'رصيد سابق'::text, null::text,
           0::numeric, 0::numeric, v_open, null::uuid
     where p_from is not null
    union all
    select l.id, l.entry_date, l.entry_type, l.ref_no, l.note, l.debit, l.credit,
           v_open + sum(l.credit - l.debit) over (order by l.entry_date, l.id), l.source_id
      from public.supplier_ledger l
     where l.supplier_id = p_supplier
       and (p_from is null or l.entry_date >= p_from) and (p_to is null or l.entry_date <= p_to)
    order by 2, 1 nulls first;
end;
$$;

create or replace function public.supplier_open_documents(p_supplier uuid)
returns table (invoice_id uuid, doc_no text, supplier_invoice_no text, kind public.ap_invoice_kind,
               invoice_date date, due_date date, total numeric, settled numeric, outstanding numeric, days_overdue integer)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  return query
    select i.id, i.doc_no, i.supplier_invoice_no, i.kind, i.invoice_date, i.due_date, i.total, i.settled_amount,
           i.total - i.settled_amount,
           greatest(((now() at time zone 'Asia/Riyadh')::date - coalesce(i.due_date, i.invoice_date)), 0)
      from public.supplier_invoices i
     where i.supplier_id = p_supplier and i.status in ('posted', 'partially_paid') and i.total > i.settled_amount
     order by coalesce(i.due_date, i.invoice_date), i.invoice_date;
end;
$$;

-- الأعمار حسب تاريخ الاستحقاق في يوم محدد. الدفعات المقدمة غير الموزعة تظهر منفصلة وتُطرح من الصافي
create or replace function public.supplier_aging(p_as_of date default null)
returns table (supplier_id uuid, supplier_name text, not_due numeric, d1_30 numeric, d31_60 numeric, d61_90 numeric,
               d90_plus numeric, total_open numeric, unapplied numeric, net_balance numeric, ledger_balance numeric,
               credit_limit numeric, oldest_due date)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare
  v_day date := coalesce(p_as_of, (now() at time zone 'Asia/Riyadh')::date);
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  return query
  with open_inv as (
    select i.supplier_id, i.total - i.settled_amount as amt, v_day - coalesce(i.due_date, i.invoice_date) as late,
           coalesce(i.due_date, i.invoice_date) as due
      from public.supplier_invoices i
     where i.status in ('posted', 'partially_paid') and i.total > i.settled_amount and i.invoice_date <= v_day
  ),
  unapp as (
    select p.supplier_id, sum(p.amount - p.allocated_amount) as amt
      from public.supplier_payments p where not p.is_void and p.amount > p.allocated_amount group by 1
    union all
    select c.supplier_id, sum(c.total - c.allocated_amount)
      from public.supplier_credit_notes_open() c group by 1
  ),
  agg as (
    select supplier_id,
           coalesce(sum(amt) filter (where late <= 0), 0) as nd,
           coalesce(sum(amt) filter (where late between 1 and 30), 0) as a1,
           coalesce(sum(amt) filter (where late between 31 and 60), 0) as a2,
           coalesce(sum(amt) filter (where late between 61 and 90), 0) as a3,
           coalesce(sum(amt) filter (where late > 90), 0) as a4,
           min(due) filter (where late > 0) as oldest
      from open_inv group by 1
  ),
  ua as (select supplier_id, sum(amt) as amt from unapp group by 1)
  select s.id, s.name, coalesce(a.nd, 0), coalesce(a.a1, 0), coalesce(a.a2, 0), coalesce(a.a3, 0), coalesce(a.a4, 0),
         coalesce(a.nd + a.a1 + a.a2 + a.a3 + a.a4, 0), coalesce(u.amt, 0),
         coalesce(a.nd + a.a1 + a.a2 + a.a3 + a.a4, 0) - coalesce(u.amt, 0),
         coalesce(b.balance, 0), s.credit_limit, a.oldest
    from public.suppliers s
    left join agg a on a.supplier_id = s.id
    left join ua u on u.supplier_id = s.id
    left join public.supplier_balances b on b.supplier_id = s.id
   where a.supplier_id is not null or u.supplier_id is not null or coalesce(b.balance, 0) <> 0
   order by coalesce(a.nd + a.a1 + a.a2 + a.a3 + a.a4, 0) desc;
end;
$$;

-- الإشعارات الدائنة المفتوحة (تُعرَّف فعلياً في 0019؛ هنا نسخة فارغة حتى تعمل الأعمار قبلها)
create or replace function public.supplier_credit_notes_open()
returns table (id uuid, supplier_id uuid, total numeric, allocated_amount numeric)
language sql stable security definer set search_path = public as $$
  select null::uuid, null::uuid, 0::numeric, 0::numeric where false
$$;

create or replace function public.supplier_profile(p_supplier uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  s public.suppliers;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  select * into s from public.suppliers where id = p_supplier;
  if s.id is null then
    raise exception 'المورد غير موجود';
  end if;
  return jsonb_build_object(
    'supplier', to_jsonb(s),
    'balance', coalesce((select balance from public.supplier_balances where supplier_id = p_supplier), 0),
    'open_total', coalesce((select sum(total - settled_amount) from public.supplier_invoices
                             where supplier_id = p_supplier and status in ('posted', 'partially_paid')), 0),
    'overdue_total', coalesce((select sum(total - settled_amount) from public.supplier_invoices
                                where supplier_id = p_supplier and status in ('posted', 'partially_paid')
                                  and coalesce(due_date, invoice_date) < (now() at time zone 'Asia/Riyadh')::date), 0),
    'unapplied_payments', coalesce((select sum(amount - allocated_amount) from public.supplier_payments
                                     where supplier_id = p_supplier and not is_void), 0),
    'invoiced_12m', coalesce((select sum(total) from public.supplier_invoices
                               where supplier_id = p_supplier and kind <> 'opening' and status not in ('draft', 'void')
                                 and invoice_date >= current_date - 365), 0),
    'paid_12m', coalesce((select sum(amount) from public.supplier_payments
                           where supplier_id = p_supplier and not is_void and method <> 'opening'
                             and paid_at >= current_date - 365), 0),
    'last_payment', (select jsonb_build_object('payment_no', payment_no, 'amount', amount, 'paid_at', paid_at)
                       from public.supplier_payments where supplier_id = p_supplier and not is_void and method <> 'opening'
                      order by paid_at desc, created_at desc limit 1),
    'over_credit_limit', s.credit_limit is not null
                         and coalesce((select balance from public.supplier_balances where supplier_id = p_supplier), 0) > s.credit_limit
  );
end;
$$;

-- ---------------------------------------------------------------------
-- الصلاحيات: قراءة للمدير، ولا كتابة مباشرة (كل الكتابة عبر الدوال)
-- ---------------------------------------------------------------------
alter table public.supplier_invoices enable row level security;
alter table public.supplier_payments enable row level security;
alter table public.supplier_allocations enable row level security;
alter table public.supplier_ledger enable row level security;
alter table public.supplier_balances enable row level security;

revoke all on public.supplier_invoices, public.supplier_payments, public.supplier_allocations,
  public.supplier_ledger, public.supplier_balances from anon, authenticated;
revoke usage on sequence public.supplier_invoice_seq, public.supplier_payment_seq from anon;
grant select on public.supplier_invoices, public.supplier_payments, public.supplier_allocations,
  public.supplier_ledger, public.supplier_balances to authenticated;

create policy supplier_invoices_select on public.supplier_invoices for select to authenticated using (public.is_manager());
create policy supplier_payments_select on public.supplier_payments for select to authenticated using (public.is_manager());
create policy supplier_allocations_select on public.supplier_allocations for select to authenticated using (public.is_manager());
create policy supplier_ledger_select on public.supplier_ledger for select to authenticated using (public.is_manager());
create policy supplier_balances_select on public.supplier_balances for select to authenticated using (public.is_manager());

create trigger supplier_invoices_audit after insert or update or delete on public.supplier_invoices
  for each row execute function public.audit_trigger();
create trigger supplier_payments_audit after insert or update or delete on public.supplier_payments
  for each row execute function public.audit_trigger();
create trigger supplier_allocations_audit after insert or update or delete on public.supplier_allocations
  for each row execute function public.audit_trigger();

revoke all on function
  public._check_supplier_integrity(uuid), public.supplier_integrity_trigger(),
  public._ap_post(uuid, public.ap_entry_type, uuid, text, numeric, numeric, text, date),
  public._lock_supplier(uuid), public._invoice_refresh_status(uuid),
  public._ap_allocate(uuid, text, uuid, numeric, jsonb), public.supplier_credit_notes_open()
from public, anon, authenticated;

revoke execute on function
  public.set_supplier_opening_balance(uuid, numeric, date, text, uuid),
  public.post_supplier_payment(uuid, numeric, public.ap_payment_method, text, date, jsonb, text, uuid),
  public.allocate_supplier_credit(text, uuid, jsonb),
  public.void_supplier_payment(uuid, text),
  public.supplier_statement(uuid, date, date),
  public.supplier_open_documents(uuid),
  public.supplier_aging(date),
  public.supplier_profile(uuid)
from public, anon;
grant execute on function
  public.set_supplier_opening_balance(uuid, numeric, date, text, uuid),
  public.post_supplier_payment(uuid, numeric, public.ap_payment_method, text, date, jsonb, text, uuid),
  public.allocate_supplier_credit(text, uuid, jsonb),
  public.void_supplier_payment(uuid, text),
  public.supplier_statement(uuid, date, date),
  public.supplier_open_documents(uuid),
  public.supplier_aging(date),
  public.supplier_profile(uuid)
to authenticated;

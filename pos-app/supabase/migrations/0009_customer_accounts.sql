-- =====================================================================
-- Sales & Customers 2.0 — (1) حسابات العملاء: الآجل، التحصيلات، كشف الحساب، نقاط الولاء
--   • دفتر أستاذ للذمم (customer_ledger) ودفتر للنقاط (loyalty_ledger): إلحاق فقط، ولكل قيد مصدر فريد
--     (نوع القيد + رقم المستند) فلا يمكن ترحيل نفس المستند مرتين
--   • الأرصدة المجمّعة في customer_accounts تُحدَّث فقط داخل دوال الترحيل
--   • التحصيل النقدي من الدرج يُسجَّل تلقائياً كإيداع في وردية الموظف (مثل المصروفات)
-- إضافة فقط: لا تغيير على جداول أو دوال سابقة
-- =====================================================================

-- طرق جديدة: البيع الآجل، والإرجاع إلى حساب العميل (تُستخدم في 0011)
alter type public.payment_method add value if not exists 'on_account';
alter type public.refund_method add value if not exists 'account';

--create type public.ar_entry_type as enum ('sale', 'return', 'receipt', 'refund', 'void', 'adjust');
create type public.loyalty_entry_type as enum ('earn', 'redeem', 'return_reverse', 'return_restore', 'adjust');
create type public.collection_method as enum ('cash_drawer', 'cash', 'card', 'transfer');
create type public.collection_kind as enum ('receipt', 'refund');

alter table public.store_settings
  add column loyalty_enabled boolean not null default false,
  add column loyalty_points_per_sar numeric(8,4) not null default 0.1
    check (loyalty_points_per_sar >= 0 and loyalty_points_per_sar <= 100),
  add column loyalty_point_value numeric(8,4) not null default 0.1
    check (loyalty_point_value >= 0 and loyalty_point_value <= 100),
  add column loyalty_min_redeem integer not null default 50 check (loyalty_min_redeem >= 1),
  add column loyalty_max_redeem_pct numeric(5,2) not null default 50
    check (loyalty_max_redeem_pct > 0 and loyalty_max_redeem_pct <= 100),
  add column allow_cashier_credit boolean not null default false,
  add column reservation_days integer not null default 3 check (reservation_days between 1 and 60);

-- ---------------------------------------------------------------------
-- الأرصدة (لكل عميل صف واحد، يُنشأ عند أول حركة أو عند تحديد حد الائتمان)
--   account_balance > 0 : على العميل للمتجر      < 0 : رصيد دائن للعميل (عربون/مرتجع إلى الحساب)
--   credit_limit null   : البيع الآجل غير مسموح لهذا العميل
-- ---------------------------------------------------------------------
create table public.customer_accounts (
  customer_id uuid primary key references public.customers (id) on delete restrict,
  credit_limit numeric(12,2) check (credit_limit is null or credit_limit >= 0),
  account_balance numeric(12,2) not null default 0,
  loyalty_points integer not null default 0,
  updated_at timestamptz not null default now()
);

create table public.customer_ledger (
  id bigint generated always as identity primary key,
  customer_id uuid not null references public.customers (id) on delete restrict,
  entry_type public.ar_entry_type not null,
  source_id uuid not null,
  ref_no text,
  debit numeric(12,2) not null default 0 check (debit >= 0),
  credit numeric(12,2) not null default 0 check (credit >= 0),
  balance_after numeric(12,2) not null,
  note text,
  created_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now(),
  constraint ledger_one_side check ((debit > 0) <> (credit > 0)),
  -- منع الترحيل المزدوج لنفس المستند
  constraint ledger_unique_source unique (entry_type, source_id)
);
create index customer_ledger_customer_idx on public.customer_ledger (customer_id, created_at, id);

create table public.loyalty_ledger (
  id bigint generated always as identity primary key,
  customer_id uuid not null references public.customers (id) on delete restrict,
  entry_type public.loyalty_entry_type not null,
  source_id uuid not null,
  ref_no text,
  points integer not null check (points <> 0),
  balance_after integer not null,
  note text,
  created_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now(),
  constraint loyalty_unique_source unique (entry_type, source_id)
);
create index loyalty_ledger_customer_idx on public.loyalty_ledger (customer_id, created_at, id);

create sequence public.collection_seq start 1;

create table public.customer_payments (
  id uuid primary key default gen_random_uuid(),
  receipt_no text not null unique
    default ('RCP-' || to_char(now() at time zone 'Asia/Riyadh', 'YY') || lpad(nextval('public.collection_seq')::text, 5, '0')),
  customer_id uuid not null references public.customers (id) on delete restrict,
  kind public.collection_kind not null default 'receipt',
  amount numeric(12,2) not null check (amount > 0),
  method public.collection_method not null,
  reference text,
  notes text,
  reservation_id uuid,                                   -- عربون حجز (المفتاح يُضاف في 0010)
  shift_movement_id uuid references public.shift_cash_movements (id),
  client_ref uuid unique,                                -- مفتاح منع التكرار من الواجهة
  created_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now(),
  voided_at timestamptz,
  voided_by uuid references public.profiles (id),
  void_reason text
);
create index customer_payments_customer_idx on public.customer_payments (customer_id, created_at desc);

-- ---------------------------------------------------------------------
-- الترحيل (داخلي — تستدعيه الدوال فقط)
-- ---------------------------------------------------------------------
create or replace function public._customer_account(p_customer_id uuid)
returns public.customer_accounts
language plpgsql security definer set search_path = public as $$
declare
  v public.customer_accounts;
begin
  insert into public.customer_accounts (customer_id) values (p_customer_id) on conflict do nothing;
  select * into v from public.customer_accounts where customer_id = p_customer_id for update;
  return v;
end;
$$;

create or replace function public._post_ar(
  p_customer_id uuid, p_type public.ar_entry_type, p_source_id uuid, p_ref_no text,
  p_debit numeric, p_credit numeric, p_note text default null
) returns numeric
language plpgsql security definer set search_path = public as $$
declare
  v_balance numeric;
begin
  if coalesce(p_debit, 0) = 0 and coalesce(p_credit, 0) = 0 then
    return null;
  end if;
  perform public._customer_account(p_customer_id);
  update public.customer_accounts
     set account_balance = account_balance + coalesce(p_debit, 0) - coalesce(p_credit, 0), updated_at = now()
   where customer_id = p_customer_id
  returning account_balance into v_balance;

  insert into public.customer_ledger (customer_id, entry_type, source_id, ref_no, debit, credit, balance_after, note)
  values (p_customer_id, p_type, p_source_id, p_ref_no, coalesce(p_debit, 0), coalesce(p_credit, 0), v_balance, p_note);
  return v_balance;
end;
$$;

create or replace function public._post_loyalty(
  p_customer_id uuid, p_type public.loyalty_entry_type, p_source_id uuid, p_ref_no text,
  p_points integer, p_note text default null
) returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_balance integer;
begin
  if coalesce(p_points, 0) = 0 then
    return null;
  end if;
  perform public._customer_account(p_customer_id);
  update public.customer_accounts
     set loyalty_points = loyalty_points + p_points, updated_at = now()
   where customer_id = p_customer_id
  returning loyalty_points into v_balance;

  insert into public.loyalty_ledger (customer_id, entry_type, source_id, ref_no, points, balance_after, note)
  values (p_customer_id, p_type, p_source_id, p_ref_no, p_points, v_balance, p_note);
  return v_balance;
end;
$$;

revoke all on function public._customer_account(uuid) from public, anon, authenticated;
revoke all on function public._post_ar(uuid, public.ar_entry_type, uuid, text, numeric, numeric, text) from public, anon, authenticated;
revoke all on function public._post_loyalty(uuid, public.loyalty_entry_type, uuid, text, integer, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- التحصيل من العميل / رد رصيد دائن للعميل
--   p_kind = 'receipt' : العميل يدفع (يُنقص ما عليه، أو يُنشئ رصيداً دائناً كعربون)
--   p_kind = 'refund'  : المتجر يرد للعميل رصيده الدائن (للمدير فقط، ولا يتجاوز الرصيد الدائن)
--   الكاشير: من الدرج أو شبكة أو تحويل فقط. «نقداً خارج الدرج» للمدير/المالك.
-- ---------------------------------------------------------------------
create or replace function public.record_customer_payment(
  p_customer_id uuid,
  p_amount numeric,
  p_method public.collection_method,
  p_kind public.collection_kind default 'receipt',
  p_reference text default null,
  p_notes text default null,
  p_client_ref uuid default null,
  p_reservation_id uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role public.user_role := public.current_user_role();
  v_existing public.customer_payments;
  v_acc public.customer_accounts;
  v_customer public.customers;
  v_amount numeric := round(p_amount, 2);
  v_shift uuid;
  v_movement uuid;
  v_id uuid;
  v_no text;
begin
  if v_role is null then
    raise exception 'غير مصرح';
  end if;

  -- نفس الطلب أُرسل مرتين (انقطاع شبكة/ضغط مزدوج): نعيد نفس السند دون ترحيل جديد
  if p_client_ref is not null then
    select * into v_existing from public.customer_payments where client_ref = p_client_ref;
    if v_existing.id is not null then
      if v_existing.created_by is distinct from auth.uid() or v_existing.customer_id <> p_customer_id then
        raise exception 'مرجع العملية مستخدم مسبقاً';
      end if;
      return v_existing.id;
    end if;
  end if;

  select * into v_customer from public.customers where id = p_customer_id;
  if v_customer.id is null then
    raise exception 'العميل غير موجود';
  end if;
  if v_amount is null or v_amount <= 0 then
    raise exception 'المبلغ غير صحيح';
  end if;
  if p_kind = 'refund' and v_role = 'cashier' then
    raise exception 'رد الرصيد للعميل للمدير فقط';
  end if;
  if p_method = 'cash' and v_role = 'cashier' then
    raise exception 'الكاشير يحصّل نقداً عبر الدرج فقط';
  end if;

  v_acc := public._customer_account(p_customer_id);   -- قفل حساب العميل حتى نهاية العملية
  if p_kind = 'refund' and v_amount > -v_acc.account_balance + 0.001 then
    raise exception 'لا يوجد رصيد دائن كافٍ للعميل (الرصيد الدائن %)', greatest(-v_acc.account_balance, 0);
  end if;

  insert into public.customer_payments (customer_id, kind, amount, method, reference, notes, client_ref, reservation_id)
  values (p_customer_id, p_kind, v_amount, p_method, nullif(trim(p_reference), ''), nullif(trim(p_notes), ''),
          p_client_ref, p_reservation_id)
  returning id, receipt_no into v_id, v_no;

  if p_method = 'cash_drawer' then
    select id into v_shift from public.shifts where cashier_id = auth.uid() and status = 'open';
    if v_shift is null then
      raise exception 'لا توجد لديك وردية مفتوحة — افتح وردية أو اختر طريقة أخرى';
    end if;
    insert into public.shift_cash_movements (shift_id, type, amount, reason)
    values (v_shift, case when p_kind = 'receipt' then 'in' else 'out' end::public.cash_movement_type, v_amount,
            case when p_kind = 'receipt' then 'تحصيل ' else 'رد رصيد ' end || v_no || ': ' || v_customer.name)
    returning id into v_movement;
    update public.customer_payments set shift_movement_id = v_movement where id = v_id;
  end if;

  if p_kind = 'receipt' then
    perform public._post_ar(p_customer_id, 'receipt', v_id, v_no, 0, v_amount, nullif(trim(p_notes), ''));
  else
    perform public._post_ar(p_customer_id, 'refund', v_id, v_no, v_amount, 0, nullif(trim(p_notes), ''));
  end if;
  return v_id;
end;
$$;

-- إلغاء سند (للمدير): قيد عكسي في الدفتر + حركة درج عكسية، والسند يبقى ظاهراً كملغي
create or replace function public.void_customer_payment(p_payment_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v public.customer_payments;
  v_shift public.shifts;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'سبب الإلغاء مطلوب';
  end if;
  select * into v from public.customer_payments where id = p_payment_id for update;
  if v.id is null then
    raise exception 'السند غير موجود';
  end if;
  if v.voided_at is not null then
    raise exception 'السند ملغي مسبقاً';
  end if;

  if v.shift_movement_id is not null then
    select s.* into v_shift from public.shift_cash_movements m join public.shifts s on s.id = m.shift_id
     where m.id = v.shift_movement_id;
    if v_shift.status = 'closed' then
      raise exception 'لا يمكن إلغاء سند نقدي من درج وردية مغلقة';
    end if;
    insert into public.shift_cash_movements (shift_id, type, amount, reason)
    values (v_shift.id, case when v.kind = 'receipt' then 'out' else 'in' end::public.cash_movement_type, v.amount,
            'إلغاء ' || v.receipt_no || ': ' || trim(p_reason));
  end if;

  perform public._customer_account(v.customer_id);
  if v.kind = 'receipt' then
    perform public._post_ar(v.customer_id, 'void', v.id, v.receipt_no, v.amount, 0, 'إلغاء: ' || trim(p_reason));
  else
    perform public._post_ar(v.customer_id, 'void', v.id, v.receipt_no, 0, v.amount, 'إلغاء: ' || trim(p_reason));
  end if;

  update public.customer_payments
     set voided_at = now(), voided_by = auth.uid(), void_reason = trim(p_reason)
   where id = v.id;
end;
$$;

-- حد الائتمان (null = لا يُسمح بالبيع الآجل)
create or replace function public.set_credit_limit(p_customer_id uuid, p_limit numeric)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_old numeric;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if p_limit is not null and p_limit < 0 then
    raise exception 'حد الائتمان غير صحيح';
  end if;
  if not exists (select 1 from public.customers where id = p_customer_id) then
    raise exception 'العميل غير موجود';
  end if;
  select credit_limit into v_old from public._customer_account(p_customer_id);
  update public.customer_accounts set credit_limit = round(p_limit, 2), updated_at = now()
   where customer_id = p_customer_id;
  insert into public.audit_log (table_name, record_id, action, old_data, new_data, changed_fields)
  values ('customer_accounts', p_customer_id::text, 'UPDATE',
          jsonb_build_object('credit_limit', v_old), jsonb_build_object('credit_limit', round(p_limit, 2)),
          array['credit_limit']);
end;
$$;

-- تعديل يدوي للنقاط (للمدير) بسبب إلزامي
create or replace function public.adjust_loyalty(p_customer_id uuid, p_points integer, p_reason text)
returns integer
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if coalesce(p_points, 0) = 0 or coalesce(trim(p_reason), '') = '' then
    raise exception 'أدخل عدد النقاط والسبب';
  end if;
  if not exists (select 1 from public.customers where id = p_customer_id) then
    raise exception 'العميل غير موجود';
  end if;
  return public._post_loyalty(p_customer_id, 'adjust', gen_random_uuid(), null, p_points, trim(p_reason));
end;
$$;

-- ---------------------------------------------------------------------
-- كشف حساب العميل لفترة: رصيد أول المدة + الحركات برصيد تراكمي + رصيد آخر المدة
-- ---------------------------------------------------------------------
create or replace function public.customer_statement(p_customer_id uuid, p_from date default null, p_to date default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_from timestamptz;
  v_to timestamptz;
  v_opening numeric;
  v_customer public.customers;
begin
  if not public.is_staff() then
    raise exception 'غير مصرح';
  end if;
  select * into v_customer from public.customers where id = p_customer_id;
  if v_customer.id is null then
    raise exception 'العميل غير موجود';
  end if;
  v_from := coalesce(p_from, '2000-01-01'::date)::timestamp at time zone 'Asia/Riyadh';
  v_to := (coalesce(p_to, (now() at time zone 'Asia/Riyadh')::date) + 1)::timestamp at time zone 'Asia/Riyadh';

  select coalesce(sum(debit - credit), 0) into v_opening
    from public.customer_ledger where customer_id = p_customer_id and created_at < v_from;

  return jsonb_build_object(
    'customer', jsonb_build_object('id', v_customer.id, 'name', v_customer.name, 'phone', v_customer.phone,
                                   'vat_number', v_customer.vat_number),
    'credit_limit', (select credit_limit from public.customer_accounts where customer_id = p_customer_id),
    'from', p_from,
    'to', coalesce(p_to, (now() at time zone 'Asia/Riyadh')::date),
    'opening_balance', v_opening,
    'entries', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', x.id, 'date', x.created_at, 'type', x.entry_type, 'ref_no', x.ref_no, 'source_id', x.source_id,
               'debit', x.debit, 'credit', x.credit, 'note', x.note, 'balance', x.balance)
             order by x.created_at, x.id)
        from (
          select e.*, v_opening + sum(e.debit - e.credit) over (order by e.created_at, e.id) as balance
            from public.customer_ledger e
           where e.customer_id = p_customer_id and e.created_at >= v_from and e.created_at < v_to) x), '[]'::jsonb),
    'total_debit', (select coalesce(sum(debit), 0) from public.customer_ledger
                     where customer_id = p_customer_id and created_at >= v_from and created_at < v_to),
    'total_credit', (select coalesce(sum(credit), 0) from public.customer_ledger
                      where customer_id = p_customer_id and created_at >= v_from and created_at < v_to),
    'closing_balance', v_opening + (select coalesce(sum(debit - credit), 0) from public.customer_ledger
                                     where customer_id = p_customer_id and created_at >= v_from and created_at < v_to)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- الذمم المدينة وأعمارها (للمدير)
--   الأعمار بطريقة FIFO: المبلغ المستحق يُنسب لأحدث فواتير الآجل، والتحصيل يسدد الأقدم أولاً
-- ---------------------------------------------------------------------
create or replace function public.receivables_report()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  return (
    with bal as (
      select a.customer_id, a.account_balance, a.credit_limit
        from public.customer_accounts a where a.account_balance <> 0
    ),
    debits as (
      select l.customer_id, l.debit, l.created_at,
             sum(l.debit) over (partition by l.customer_id order by l.created_at desc, l.id desc) as cum
        from public.customer_ledger l
        join bal b on b.customer_id = l.customer_id and b.account_balance > 0
       where l.debit > 0
    ),
    open_parts as (
      select d.customer_id, d.created_at,
             least(d.debit, greatest(b.account_balance - (d.cum - d.debit), 0)) as open_amount
        from debits d join bal b on b.customer_id = d.customer_id
    ),
    aging as (
      select customer_id,
             sum(open_amount) filter (where now() - created_at <= interval '30 days') as d0_30,
             sum(open_amount) filter (where now() - created_at > interval '30 days' and now() - created_at <= interval '60 days') as d31_60,
             sum(open_amount) filter (where now() - created_at > interval '60 days' and now() - created_at <= interval '90 days') as d61_90,
             sum(open_amount) filter (where now() - created_at > interval '90 days') as d90_plus
        from open_parts group by customer_id
    ),
    rows as (
      select c.id, c.name, c.phone, b.account_balance as balance, b.credit_limit,
             coalesce(a.d0_30, 0) as d0_30, coalesce(a.d31_60, 0) as d31_60,
             coalesce(a.d61_90, 0) as d61_90, coalesce(a.d90_plus, 0) as d90_plus,
             (select max(created_at) from public.customer_payments p
               where p.customer_id = c.id and p.kind = 'receipt' and p.voided_at is null) as last_payment_at
        from bal b join public.customers c on c.id = b.customer_id
         left join aging a on a.customer_id = b.customer_id
    )
    select jsonb_build_object(
      'total_receivable', coalesce((select sum(balance) from rows where balance > 0), 0),
      'total_credit_balances', coalesce((select -sum(balance) from rows where balance < 0), 0),
      'd0_30', coalesce((select sum(d0_30) from rows), 0),
      'd31_60', coalesce((select sum(d31_60) from rows), 0),
      'd61_90', coalesce((select sum(d61_90) from rows), 0),
      'd90_plus', coalesce((select sum(d90_plus) from rows), 0),
      'customers', coalesce((select jsonb_agg(to_jsonb(r) order by r.balance desc) from rows r), '[]'::jsonb)
    )
  );
end;
$$;

-- ---------------------------------------------------------------------
-- RLS: الموظفون يقرؤون (الكاشير يحتاج الرصيد والنقاط عند البيع)، والكتابة عبر الدوال فقط
-- ---------------------------------------------------------------------
alter table public.customer_accounts enable row level security;
alter table public.customer_ledger enable row level security;
alter table public.loyalty_ledger enable row level security;
alter table public.customer_payments enable row level security;

revoke all on public.customer_accounts, public.customer_ledger, public.loyalty_ledger, public.customer_payments from anon;
revoke insert, update, delete on public.customer_accounts, public.customer_ledger, public.loyalty_ledger,
  public.customer_payments from authenticated;
grant select on public.customer_accounts, public.customer_ledger, public.loyalty_ledger, public.customer_payments
  to authenticated;
revoke usage on sequence public.collection_seq from anon;

create policy customer_accounts_select on public.customer_accounts for select to authenticated using (public.is_staff());
create policy customer_ledger_select on public.customer_ledger for select to authenticated using (public.is_staff());
create policy loyalty_ledger_select on public.loyalty_ledger for select to authenticated using (public.is_staff());
create policy customer_payments_select on public.customer_payments for select to authenticated using (public.is_staff());

create trigger customer_payments_audit after insert or update or delete on public.customer_payments
  for each row execute function public.audit_trigger();

revoke execute on function
  public.record_customer_payment(uuid, numeric, public.collection_method, public.collection_kind, text, text, uuid, uuid),
  public.void_customer_payment(uuid, text),
  public.set_credit_limit(uuid, numeric),
  public.adjust_loyalty(uuid, integer, text),
  public.customer_statement(uuid, date, date),
  public.receivables_report()
from public, anon;
grant execute on function
  public.record_customer_payment(uuid, numeric, public.collection_method, public.collection_kind, text, text, uuid, uuid),
  public.void_customer_payment(uuid, text),
  public.set_credit_limit(uuid, numeric),
  public.adjust_loyalty(uuid, integer, text),
  public.customer_statement(uuid, date, date),
  public.receivables_report()
to authenticated;

-- =====================================================================
-- الورديات وإغلاق الصندوق
--   • كل موظف يفتح وردية برصيد افتتاحي، وكل بيع/مرتجع يُربط بورديته المفتوحة تلقائياً
--   • حركات نقدية يدوية على الدرج (إيداع/سحب) بسبب إلزامي
--   • الإغلاق: الموظف يدخل النقد المعدود (دون رؤية المتوقع)، والنظام يحسب العجز/الزيادة
-- إضافة فقط: لا تغيير على دوال البيع والمرتجعات، والربط يتم عبر triggers
-- =====================================================================

create type public.shift_status as enum ('open', 'closed');
create type public.cash_movement_type as enum ('in', 'out');

alter table public.store_settings
  add column require_shift boolean not null default true;

create sequence public.shift_seq start 1;

create table public.shifts (
  id uuid primary key default gen_random_uuid(),
  shift_no text not null unique,
  cashier_id uuid not null references public.profiles (id),
  status public.shift_status not null default 'open',
  opening_cash numeric(12,2) not null check (opening_cash >= 0),
  opened_at timestamptz not null default now(),
  opening_notes text,
  -- لقطة الأرقام عند الإغلاق (تبقى ثابتة حتى لو تغيرت البيانات لاحقاً)
  closed_at timestamptz,
  closed_by uuid references public.profiles (id),
  counted_cash numeric(12,2) check (counted_cash is null or counted_cash >= 0),
  expected_cash numeric(12,2),
  cash_difference numeric(12,2),
  summary jsonb,
  closing_notes text
);
-- وردية مفتوحة واحدة فقط لكل موظف
create unique index shifts_one_open_per_cashier on public.shifts (cashier_id) where status = 'open';
create index shifts_opened_idx on public.shifts (opened_at desc);

create table public.shift_cash_movements (
  id uuid primary key default gen_random_uuid(),
  shift_id uuid not null references public.shifts (id) on delete cascade,
  type public.cash_movement_type not null,
  amount numeric(12,2) not null check (amount > 0),
  reason text not null check (length(trim(reason)) > 0),
  created_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now()
);
create index shift_cash_movements_shift_idx on public.shift_cash_movements (shift_id);

alter table public.sales add column shift_id uuid references public.shifts (id);
alter table public.returns add column shift_id uuid references public.shifts (id);
create index sales_shift_idx on public.sales (shift_id);
create index returns_shift_idx on public.returns (shift_id);

-- ---------------------------------------------------------------------
-- ربط البيع/المرتجع بالوردية المفتوحة للموظف
-- ---------------------------------------------------------------------
create or replace function public.attach_open_shift()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_require boolean := (select require_shift from public.store_settings where id = 1);
begin
  select id into new.shift_id
    from public.shifts
   where cashier_id = new.cashier_id and status = 'open';

  if new.shift_id is null and v_require then
    if tg_table_name = 'sales' then
      raise exception 'لا توجد وردية مفتوحة — افتح الوردية أولاً';
    -- المرتجع بغير النقد لا يمس الدرج، فلا يحتاج وردية
    elsif (to_jsonb(new) ->> 'refund_method') = 'cash' then
      raise exception 'لا توجد وردية مفتوحة — افتح الوردية أولاً';
    end if;
  end if;
  return new;
end;
$$;

create trigger sales_attach_shift before insert on public.sales
  for each row execute function public.attach_open_shift();
create trigger returns_attach_shift before insert on public.returns
  for each row execute function public.attach_open_shift();

-- ---------------------------------------------------------------------
-- ملخص الوردية (محسوب لحظياً)
-- ---------------------------------------------------------------------
create or replace function public._shift_numbers(p_shift_id uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  with
  sh as (select * from public.shifts where id = p_shift_id),
  s as (select * from public.sales where shift_id = p_shift_id),
  pay as (
    select p.method, sum(p.amount) as amount
      from public.sale_payments p join s on s.id = p.sale_id
     group by p.method
  ),
  r as (select * from public.returns where shift_id = p_shift_id),
  mv as (
    select coalesce(sum(amount) filter (where type = 'in'), 0) as cash_in,
           coalesce(sum(amount) filter (where type = 'out'), 0) as cash_out
      from public.shift_cash_movements where shift_id = p_shift_id
  ),
  n as (
    select
      (select opening_cash from sh) as opening_cash,
      coalesce((select amount from pay where method = 'cash'), 0)
        - coalesce((select sum(change_amount) from s), 0) as cash_sales,
      coalesce((select amount from pay where method = 'card'), 0) as card_sales,
      coalesce((select amount from pay where method = 'transfer'), 0) as transfer_sales,
      coalesce((select amount from pay where method = 'exchange_credit'), 0) as exchange_credit,
      coalesce((select sum(total) from s), 0) as total_sales,
      (select count(*) from s) as sales_count,
      coalesce((select sum(total) from r where refund_method = 'cash'), 0) as cash_refunds,
      coalesce((select sum(total) from r where refund_method = 'card'), 0) as card_refunds,
      coalesce((select sum(total) from r where refund_method = 'transfer'), 0) as transfer_refunds,
      coalesce((select sum(total) from r where refund_method = 'exchange'), 0) as exchange_returns,
      (select count(*) from r) as returns_count,
      (select cash_in from mv) as cash_in,
      (select cash_out from mv) as cash_out
  )
  select jsonb_build_object(
    'opening_cash', opening_cash,
    'cash_sales', cash_sales,
    'card_sales', card_sales,
    'transfer_sales', transfer_sales,
    'exchange_credit', exchange_credit,
    'total_sales', total_sales,
    'sales_count', sales_count,
    'cash_refunds', cash_refunds,
    'card_refunds', card_refunds,
    'transfer_refunds', transfer_refunds,
    'exchange_returns', exchange_returns,
    'returns_count', returns_count,
    'cash_in', cash_in,
    'cash_out', cash_out,
    'expected_cash', opening_cash + cash_sales - cash_refunds + cash_in - cash_out
  ) from n
$$;
revoke all on function public._shift_numbers(uuid) from public, anon, authenticated;

-- الملخص لمن يحق له: المدير/المالك، أو صاحب الوردية بعد إغلاقها.
-- أثناء الوردية لا يرى الكاشير النقد المتوقع (عدّ أعمى عند الإغلاق).
create or replace function public.shift_summary(p_shift_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_shift public.shifts;
  v_numbers jsonb;
begin
  select * into v_shift from public.shifts where id = p_shift_id;
  if v_shift.id is null then
    raise exception 'الوردية غير موجودة';
  end if;
  if not (public.is_manager() or (public.is_staff() and v_shift.cashier_id = auth.uid())) then
    raise exception 'غير مصرح';
  end if;

  v_numbers := coalesce(v_shift.summary, public._shift_numbers(p_shift_id));

  if v_shift.status = 'open' and not public.is_manager() then
    v_numbers := jsonb_build_object(
      'opening_cash', v_numbers -> 'opening_cash',
      'sales_count', v_numbers -> 'sales_count',
      'returns_count', v_numbers -> 'returns_count',
      'total_sales', v_numbers -> 'total_sales'
    );
  end if;

  return jsonb_build_object(
    'id', v_shift.id,
    'shift_no', v_shift.shift_no,
    'status', v_shift.status,
    'cashier_id', v_shift.cashier_id,
    'cashier_name', (select full_name from public.profiles where id = v_shift.cashier_id),
    'opened_at', v_shift.opened_at,
    'closed_at', v_shift.closed_at,
    'closed_by_name', (select full_name from public.profiles where id = v_shift.closed_by),
    'counted_cash', v_shift.counted_cash,
    'cash_difference', v_shift.cash_difference,
    'opening_notes', v_shift.opening_notes,
    'closing_notes', v_shift.closing_notes,
    'numbers', v_numbers,
    'movements', coalesce((
      select jsonb_agg(jsonb_build_object('type', type, 'amount', amount, 'reason', reason, 'created_at', created_at)
                       order by created_at)
        from public.shift_cash_movements where shift_id = p_shift_id), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- فتح / حركة نقدية / إغلاق
-- ---------------------------------------------------------------------
create or replace function public.open_shift(p_opening_cash numeric, p_notes text default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if not public.is_staff() then
    raise exception 'غير مصرح';
  end if;
  if p_opening_cash is null or p_opening_cash < 0 then
    raise exception 'الرصيد الافتتاحي غير صحيح';
  end if;
  if exists (select 1 from public.shifts where cashier_id = auth.uid() and status = 'open') then
    raise exception 'لديك وردية مفتوحة بالفعل';
  end if;

  insert into public.shifts (shift_no, cashier_id, opening_cash, opening_notes)
  values (
    'SH-' || to_char(now() at time zone 'Asia/Riyadh', 'YY') || lpad(nextval('public.shift_seq')::text, 5, '0'),
    auth.uid(), round(p_opening_cash, 2), nullif(trim(p_notes), '')
  ) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.add_cash_movement(
  p_type public.cash_movement_type, p_amount numeric, p_reason text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_shift uuid;
  v_id uuid;
begin
  if not public.is_staff() then
    raise exception 'غير مصرح';
  end if;
  select id into v_shift from public.shifts where cashier_id = auth.uid() and status = 'open';
  if v_shift is null then
    raise exception 'لا توجد وردية مفتوحة';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'المبلغ غير صحيح';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'السبب مطلوب';
  end if;

  insert into public.shift_cash_movements (shift_id, type, amount, reason)
  values (v_shift, p_type, round(p_amount, 2), trim(p_reason))
  returning id into v_id;
  return v_id;
end;
$$;

-- الموظف يغلق ورديته، والمدير/المالك يستطيع إغلاق أي وردية (مثلاً نسيها الموظف)
create or replace function public.close_shift(p_shift_id uuid, p_counted_cash numeric, p_notes text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_shift public.shifts;
  v_numbers jsonb;
  v_expected numeric;
begin
  select * into v_shift from public.shifts where id = p_shift_id for update;
  if v_shift.id is null then
    raise exception 'الوردية غير موجودة';
  end if;
  if not (public.is_manager() or (public.is_staff() and v_shift.cashier_id = auth.uid())) then
    raise exception 'غير مصرح';
  end if;
  if v_shift.status <> 'open' then
    raise exception 'الوردية مغلقة بالفعل';
  end if;
  if p_counted_cash is null or p_counted_cash < 0 then
    raise exception 'أدخل النقد المعدود في الدرج';
  end if;

  v_numbers := public._shift_numbers(p_shift_id);
  v_expected := (v_numbers ->> 'expected_cash')::numeric;

  update public.shifts
     set status = 'closed',
         closed_at = now(),
         closed_by = auth.uid(),
         counted_cash = round(p_counted_cash, 2),
         expected_cash = v_expected,
         cash_difference = round(p_counted_cash, 2) - v_expected,
         summary = v_numbers,
         closing_notes = nullif(trim(p_notes), '')
   where id = p_shift_id;

  return public.shift_summary(p_shift_id);
end;
$$;

-- ---------------------------------------------------------------------
-- RLS: قراءة فقط (الكتابة عبر الدوال)
-- ---------------------------------------------------------------------
alter table public.shifts enable row level security;
alter table public.shift_cash_movements enable row level security;

revoke all on public.shifts, public.shift_cash_movements from anon;
revoke insert, update, delete on public.shifts, public.shift_cash_movements from authenticated;
grant select on public.shifts, public.shift_cash_movements to authenticated;
-- المبالغ المتوقعة والفروقات لا تُقرأ مباشرة؛ الكاشير يراها عبر shift_summary بعد الإغلاق
revoke select on public.shifts from authenticated;
grant select (id, shift_no, cashier_id, status, opening_cash, opened_at, closed_at, closed_by, opening_notes)
  on public.shifts to authenticated;

create policy shifts_select on public.shifts for select to authenticated
  using (public.is_manager() or (public.is_staff() and cashier_id = auth.uid()));
create policy shift_movements_select on public.shift_cash_movements for select to authenticated
  using (exists (select 1 from public.shifts s where s.id = shift_id));

create trigger shifts_audit after insert or update or delete on public.shifts
  for each row execute function public.audit_trigger();
create trigger shift_cash_movements_audit after insert or update or delete on public.shift_cash_movements
  for each row execute function public.audit_trigger();

-- ---------------------------------------------------------------------
-- قائمة الورديات مع الأرقام (المدير يرى الكل، الموظف ورديّاته فقط وبدون المتوقع للمفتوحة)
-- ---------------------------------------------------------------------
create or replace function public.list_shifts(p_from date default null, p_to date default null)
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(row order by (row ->> 'opened_at') desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'id', s.id,
      'shift_no', s.shift_no,
      'status', s.status,
      'cashier_name', p.full_name,
      'is_mine', s.cashier_id = auth.uid(),
      'opened_at', s.opened_at,
      'closed_at', s.closed_at,
      'opening_cash', s.opening_cash,
      'total_sales', coalesce((s.summary ->> 'total_sales')::numeric,
                              (select coalesce(sum(total), 0) from public.sales where shift_id = s.id)),
      'expected_cash', case when public.is_manager() or s.status = 'closed' then
                         coalesce(s.expected_cash, (public._shift_numbers(s.id) ->> 'expected_cash')::numeric) end,
      'counted_cash', s.counted_cash,
      'cash_difference', s.cash_difference
    ) as row
      from public.shifts s
      left join public.profiles p on p.id = s.cashier_id
     where public.is_staff()
       and (public.is_manager() or s.cashier_id = auth.uid())
       and (p_from is null or s.opened_at >= p_from::timestamp at time zone 'Asia/Riyadh')
       and (p_to is null or s.opened_at < (p_to + 1)::timestamp at time zone 'Asia/Riyadh')
     order by s.opened_at desc
     limit 200
  ) t
$$;

grant execute on function
  public.shift_summary(uuid),
  public.open_shift(numeric, text),
  public.add_cash_movement(public.cash_movement_type, numeric, text),
  public.close_shift(uuid, numeric, text),
  public.list_shifts(date, date)
to authenticated;

-- الدوال الجديدة تُمنح لـ PUBLIC افتراضياً في PostgreSQL — نقصرها على المستخدمين المسجلين
revoke execute on function
  public.attach_open_shift(),
  public.shift_summary(uuid),
  public.open_shift(numeric, text),
  public.add_cash_movement(public.cash_movement_type, numeric, text),
  public.close_shift(uuid, numeric, text),
  public.list_shifts(date, date)
from public, anon;

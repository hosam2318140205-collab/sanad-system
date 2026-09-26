-- =====================================================================
-- 0019 مرتجعات الموردين والإشعارات الدائنة وتكاليف الوصول (PR #9 — المرحلة 3)
--   • مرتجع للمورد: مسودة ← معتمد ← مشحون (يخرج من مخزون موقعه، لا أكثر من المتاح) ← إشعار دائن
--     يُسعَّر بتكلفة الفاتورة الأصلية (أو الاستلام، أو المتوسط الحالي إن لم يُربط). الفرق عن المتوسط = فرق تكلفة
--   • إشعار دائن: مرتجع / تعديل سعر (يخفض التكلفة: نصيب المخزون للمتوسط والمباع فرق تكلفة) / خصم (بلا أثر على التكلفة)
--     ضريبته عكسية، ويُطبَّق على الفواتير (صريح أو الأقدم أولاً) والباقي رصيد دائن لدى المورد
--   • استرداد من المورد (نقداً/درج/تحويل) يستهلك رصيداً دائناً غير مطبَّق
--   • تكاليف الوصول (شحن/جمارك/نقل/أخرى): توزيع على سطور الاستلام بالقيمة أو الكمية أو يدوياً، مجموعها يطابق حرفياً
--     كل سطر له مورد (شركة الشحن، الجمارك…) فيصبح فاتورة مصروف مستحقة عليه
-- =====================================================================

alter type public.movement_type add value if not exists 'supplier_return';
alter type public.loc_movement_type add value if not exists 'supplier_return';
alter type public.ap_entry_type add value if not exists 'void_refund';

alter table public.cost_adjustments drop constraint cost_adjustments_source_type_check;
alter table public.cost_adjustments add constraint cost_adjustments_source_type_check
  check (source_type in ('invoice_price', 'invoice_void', 'landed_cost', 'landed_cost_void', 'credit_note', 'credit_note_void',
                         'supplier_return'));

-- ---------------------------------------------------------------------
-- المرتجعات
-- ---------------------------------------------------------------------
create sequence public.supplier_return_seq start 1;
create sequence public.supplier_credit_seq start 1;
create sequence public.supplier_refund_seq start 1;
create sequence public.landed_cost_seq start 1;

create table public.supplier_returns (
  id uuid primary key default gen_random_uuid(),
  return_no text not null unique
    default 'SRT-' || to_char(now() at time zone 'Asia/Riyadh', 'YY') || lpad(nextval('public.supplier_return_seq')::text, 5, '0'),
  supplier_id uuid not null references public.suppliers (id),
  location_id uuid not null references public.locations (id),
  status text not null default 'draft' check (status in ('draft', 'approved', 'shipped', 'credited', 'cancelled')),
  reason text not null check (length(trim(reason)) > 0),
  notes text,
  client_ref uuid unique,
  created_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now(),
  approved_by uuid references public.profiles (id),
  approved_at timestamptz,
  shipped_by uuid references public.profiles (id),
  shipped_at timestamptz,
  cancel_reason text
);
create index supplier_returns_supplier_idx on public.supplier_returns (supplier_id, status);

create table public.supplier_return_items (
  id uuid primary key default gen_random_uuid(),
  return_id uuid not null references public.supplier_returns (id) on delete cascade,
  receipt_item_id uuid references public.goods_receipt_items (id),
  variant_id uuid not null references public.product_variants (id),
  qty integer not null check (qty > 0),
  unit_cost numeric(12,2) not null check (unit_cost >= 0),        -- أساس الإشعار الدائن (قبل الضريبة)
  avg_cost_at_ship numeric(12,2)
);
create index supplier_return_items_return_idx on public.supplier_return_items (return_id);

-- ---------------------------------------------------------------------
-- الإشعارات الدائنة والاستردادات
-- ---------------------------------------------------------------------
create table public.supplier_credit_notes (
  id uuid primary key default gen_random_uuid(),
  cn_no text not null unique
    default 'SCN-' || to_char(now() at time zone 'Asia/Riyadh', 'YY') || lpad(nextval('public.supplier_credit_seq')::text, 5, '0'),
  supplier_id uuid not null references public.suppliers (id),
  kind text not null check (kind in ('return', 'price', 'rebate')),
  status text not null default 'posted' check (status in ('posted', 'void')),
  supplier_credit_no text,
  credit_date date not null default (now() at time zone 'Asia/Riyadh')::date,
  return_id uuid references public.supplier_returns (id),
  invoice_id uuid references public.supplier_invoices (id),
  subtotal numeric(12,2) not null check (subtotal >= 0),
  vat_amount numeric(12,2) not null default 0 check (vat_amount >= 0),
  total numeric(12,2) not null check (total > 0),
  allocated_amount numeric(12,2) not null default 0 check (allocated_amount >= 0),
  notes text,
  client_ref uuid unique,
  created_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now(),
  void_reason text,
  voided_by uuid references public.profiles (id),
  voided_at timestamptz,
  constraint scn_alloc_le_total check (allocated_amount <= total)
);
create index supplier_credit_notes_supplier_idx on public.supplier_credit_notes (supplier_id, status);
create unique index supplier_credit_notes_return_key on public.supplier_credit_notes (return_id) where return_id is not null and status = 'posted';

create table public.supplier_credit_note_items (
  id uuid primary key default gen_random_uuid(),
  credit_note_id uuid not null references public.supplier_credit_notes (id) on delete cascade,
  receipt_item_id uuid references public.goods_receipt_items (id),
  variant_id uuid references public.product_variants (id),
  description text,
  qty integer not null default 1 check (qty > 0),
  unit_amount numeric(12,2) not null check (unit_amount >= 0),
  line_total numeric(12,2) not null check (line_total >= 0),
  vat_rate numeric(5,2) not null default 0,
  vat_amount numeric(12,2) not null default 0
);
create index supplier_credit_note_items_cn_idx on public.supplier_credit_note_items (credit_note_id);

create table public.supplier_refunds (
  id uuid primary key default gen_random_uuid(),
  refund_no text not null unique
    default 'SRF-' || to_char(now() at time zone 'Asia/Riyadh', 'YY') || lpad(nextval('public.supplier_refund_seq')::text, 5, '0'),
  supplier_id uuid not null references public.suppliers (id),
  amount numeric(12,2) not null check (amount > 0),
  method public.ap_payment_method not null check (method <> 'opening'),
  reference text,
  received_at date not null default (now() at time zone 'Asia/Riyadh')::date,
  shift_id uuid references public.shifts (id),
  shift_movement_id uuid references public.shift_cash_movements (id),
  notes text,
  client_ref uuid unique,
  created_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now()
);

-- الاسترداد يستهلك أرصدة دائنة غير مطبّقة (دفعات مقدمة أو إشعارات)
create table public.supplier_refund_allocations (
  id bigint generated always as identity primary key,
  refund_id uuid not null references public.supplier_refunds (id),
  supplier_id uuid not null references public.suppliers (id),
  source_type text not null check (source_type in ('payment', 'credit_note')),
  source_id uuid not null,
  amount numeric(12,2) not null check (amount > 0)
);
create index supplier_refund_allocations_source_idx on public.supplier_refund_allocations (source_type, source_id);

-- ---------------------------------------------------------------------
-- تكاليف الوصول
-- ---------------------------------------------------------------------
create table public.landed_cost_vouchers (
  id uuid primary key default gen_random_uuid(),
  lc_no text not null unique
    default 'LCV-' || to_char(now() at time zone 'Asia/Riyadh', 'YY') || lpad(nextval('public.landed_cost_seq')::text, 5, '0'),
  status text not null default 'posted' check (status in ('posted', 'void')),
  method text not null check (method in ('value', 'qty', 'manual')),
  total_amount numeric(12,2) not null check (total_amount > 0),
  notes text,
  client_ref uuid unique,
  created_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now(),
  void_reason text,
  voided_by uuid references public.profiles (id),
  voided_at timestamptz
);

create table public.landed_cost_lines (
  id uuid primary key default gen_random_uuid(),
  voucher_id uuid not null references public.landed_cost_vouchers (id) on delete cascade,
  cost_type text not null check (cost_type in ('freight', 'customs', 'transport', 'other')),
  description text,
  supplier_id uuid not null references public.suppliers (id),
  supplier_invoice_no text,
  amount numeric(12,2) not null check (amount > 0),         -- قبل الضريبة: يدخل التكلفة
  vat_amount numeric(12,2) not null default 0 check (vat_amount >= 0),   -- ضريبة مدخلات: لا تدخل التكلفة
  expense_invoice_id uuid references public.supplier_invoices (id)
);

create table public.landed_cost_allocations (
  id bigint generated always as identity primary key,
  voucher_id uuid not null references public.landed_cost_vouchers (id) on delete cascade,
  receipt_item_id uuid not null references public.goods_receipt_items (id),
  variant_id uuid not null references public.product_variants (id),
  qty integer not null,
  basis numeric(14,2) not null,
  amount numeric(12,2) not null
);
create index landed_cost_allocations_voucher_idx on public.landed_cost_allocations (voucher_id);
create index landed_cost_allocations_gri_idx on public.landed_cost_allocations (receipt_item_id);

-- ---------------------------------------------------------------------
-- القيد: يشمل الآن الإشعارات والاستردادات
-- ---------------------------------------------------------------------
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
    select p.payment_no as no, p.allocated_amount,
           coalesce((select sum(a.amount) from public.supplier_allocations a
                      where a.source_type = 'payment' and a.source_id = p.id and a.voided_at is null), 0)
         + coalesce((select sum(f.amount) from public.supplier_refund_allocations f
                      where f.source_type = 'payment' and f.source_id = p.id), 0) as alloc
      from public.supplier_payments p where p.supplier_id = p_supplier
    union all
    select c.cn_no, c.allocated_amount,
           coalesce((select sum(a.amount) from public.supplier_allocations a
                      where a.source_type = 'credit_note' and a.source_id = c.id and a.voided_at is null), 0)
         + coalesce((select sum(f.amount) from public.supplier_refund_allocations f
                      where f.source_type = 'credit_note' and f.source_id = c.id), 0)
      from public.supplier_credit_notes c where c.supplier_id = p_supplier
  loop
    if r.allocated_amount <> r.alloc then
      raise exception 'تعارض توزيع %: % مقابل %', r.no, r.allocated_amount, r.alloc;
    end if;
  end loop;
end;
$$;

create constraint trigger supplier_credit_notes_integrity after insert or update on public.supplier_credit_notes
  deferrable initially deferred for each row execute function public.supplier_integrity_trigger();
create constraint trigger supplier_refund_allocations_integrity after insert on public.supplier_refund_allocations
  deferrable initially deferred for each row execute function public.supplier_integrity_trigger();

create or replace function public.supplier_credit_notes_open()
returns table (id uuid, supplier_id uuid, total numeric, allocated_amount numeric)
language sql stable security definer set search_path = public as $$
  select c.id, c.supplier_id, c.total, c.allocated_amount from public.supplier_credit_notes c
   where c.status = 'posted' and c.total > c.allocated_amount
$$;

-- ---------------------------------------------------------------------
-- المرتجعات: إنشاء، اعتماد، شحن، إلغاء
--   p_items: [{receipt_item_id, qty}] أو [{variant_id, qty}] (بلا ربط: بالمتوسط الحالي)
-- ---------------------------------------------------------------------
create or replace function public.create_supplier_return(
  p_supplier uuid, p_location uuid, p_items jsonb, p_reason text, p_notes text default null, p_client_ref uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  e jsonb;
  g record;
  v_cost numeric;
  v_variant uuid;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'سبب الإرجاع مطلوب';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'لا توجد أصناف';
  end if;
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtextextended('srt:' || p_client_ref::text, 0));
    select id into v_id from public.supplier_returns where client_ref = p_client_ref;
    if v_id is not null then
      return v_id;
    end if;
  end if;
  perform public._lock_supplier(p_supplier);
  if (select kind from public.locations where id = p_location and is_active) not in ('store', 'warehouse') then
    raise exception 'موقع غير صالح';
  end if;
  insert into public.supplier_returns (supplier_id, location_id, reason, notes, client_ref)
  values (p_supplier, p_location, trim(p_reason), nullif(trim(p_notes), ''), p_client_ref)
  returning id into v_id;

  for e in select * from jsonb_array_elements(p_items) loop
    if coalesce((e ->> 'qty')::integer, 0) <= 0 then
      raise exception 'كمية غير صحيحة';
    end if;
    if e ? 'receipt_item_id' then
      select gi.*, gr.supplier_id as sup into g
        from public.goods_receipt_items gi join public.goods_receipts gr on gr.id = gi.receipt_id
       where gi.id = (e ->> 'receipt_item_id')::uuid;
      if g.id is null or g.sup <> p_supplier then
        raise exception 'سطر الاستلام لا يخص هذا المورد';
      end if;
      -- تكلفة الفاتورة الأصلية إن وُجدت، وإلا تكلفة الاستلام
      select coalesce((select l.unit_cost from public.supplier_invoice_items l join public.supplier_invoices i on i.id = l.invoice_id
                        where l.receipt_item_id = g.id and i.status in ('posted', 'partially_paid', 'paid')
                        order by i.posted_at desc limit 1), g.unit_cost) into v_cost;
      v_variant := g.variant_id;
    else
      v_variant := (e ->> 'variant_id')::uuid;
      select coalesce(cost_price, 0) into v_cost from public.variant_costs where variant_id = v_variant;
      if not found then
        raise exception 'الصنف غير موجود';
      end if;
    end if;
    insert into public.supplier_return_items (return_id, receipt_item_id, variant_id, qty, unit_cost)
    values (v_id, (e ->> 'receipt_item_id')::uuid, v_variant, (e ->> 'qty')::integer, coalesce(v_cost, 0));
  end loop;
  return v_id;
end;
$$;

create or replace function public.approve_supplier_return(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  r public.supplier_returns;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  select * into r from public.supplier_returns where id = p_id for update;
  if r.id is null or r.status <> 'draft' then
    raise exception 'المرتجع ليس مسودة';
  end if;
  if (select inventory_segregation from public.store_settings where id = 1) and r.created_by = auth.uid() then
    raise exception 'فصل المهام مفعّل: من أنشأ المرتجع لا يعتمده';
  end if;
  update public.supplier_returns set status = 'approved', approved_by = auth.uid(), approved_at = now() where id = p_id;
end;
$$;

create or replace function public.cancel_supplier_return(p_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'السبب مطلوب';
  end if;
  update public.supplier_returns set status = 'cancelled', cancel_reason = trim(p_reason)
   where id = p_id and status in ('draft', 'approved');
  if not found then
    raise exception 'لا يمكن إلغاء مرتجع بعد شحنه';
  end if;
end;
$$;

-- الشحن: يخرج من مخزون موقع المرتجع (لا أكثر من الموجود فيه)، مرة واحدة
create or replace function public.ship_supplier_return(p_id uuid, p_client_ref uuid default null)
returns void
language plpgsql security definer set search_path = public as $$
declare
  r public.supplier_returns;
  it record;
  v_have integer;
  v_avg numeric;
begin
  if not public.is_staff() then
    raise exception 'غير مصرح';
  end if;
  select * into r from public.supplier_returns where id = p_id for update;
  if r.id is null then
    raise exception 'المرتجع غير موجود';
  end if;
  if r.status <> 'approved' then
    if r.status in ('shipped', 'credited') then
      return;       -- ضغطة مكررة: لا أثر
    end if;
    raise exception 'المرتجع غير معتمد';
  end if;
  if not public.is_manager() and public._my_location() is distinct from r.location_id then
    raise exception 'الشحن لموظفي موقع المرتجع أو المدير فقط';
  end if;

  perform set_config('app.po_rpc', 'on', true);
  for it in select * from public.supplier_return_items where return_id = p_id order by variant_id, id loop
    -- نفس ترتيب أقفال البيع (الصنف ثم رصيد الموقع) حتى لا يحدث تعارض قفل متبادل
    perform 1 from public.product_variants where id = it.variant_id for update;
    select coalesce(qty, 0) into v_have from public.location_stock
     where location_id = r.location_id and variant_id = it.variant_id for update;
    if coalesce(v_have, 0) < it.qty then
      raise exception 'الموجود من % في % هو % فقط',
        (select sku from public.product_variants where id = it.variant_id),
        (select name from public.locations where id = r.location_id), coalesce(v_have, 0);
    end if;
    if it.receipt_item_id is not null then
      update public.goods_receipt_items set qty_returned = qty_returned + it.qty where id = it.receipt_item_id;
      update public.purchase_items set qty_returned = qty_returned + it.qty
       where id = (select purchase_item_id from public.goods_receipt_items where id = it.receipt_item_id);
    end if;
    select coalesce(cost_price, 0) into v_avg from public.variant_costs where variant_id = it.variant_id;
    update public.supplier_return_items set avg_cost_at_ship = v_avg where id = it.id;
    perform set_config('app.location_id', r.location_id::text, true);
    perform public._move_stock(it.variant_id, -it.qty, 'supplier_return', p_id, r.return_no, true);
    perform set_config('app.location_id', '', true);
    -- المخزون يخرج بالمتوسط، والإشعار بسعر الشراء: الفرق فرق تكلفة (موجب = خسارة)
    if v_avg <> it.unit_cost then
      insert into public.cost_adjustments (variant_id, source_type, source_id, qty_basis, qty_in_stock, total_delta,
                                           stock_delta, variance_delta, cost_before, cost_after)
      values (it.variant_id, 'supplier_return', p_id, it.qty, 0, round(it.qty * (v_avg - it.unit_cost), 2), 0,
              round(it.qty * (v_avg - it.unit_cost), 2), v_avg, v_avg);
    end if;
  end loop;
  perform set_config('app.po_rpc', '', true);
  update public.supplier_returns set status = 'shipped', shipped_by = auth.uid(), shipped_at = now() where id = p_id;
end;
$$;

-- ---------------------------------------------------------------------
-- الإشعار الدائن
--   return : من مرتجع مشحون (الكميات والأسعار منه)
--   price  : [{receipt_item_id, qty, unit_amount}] تخفيض سعر لكل قطعة ← يخفض التكلفة
--   rebate : [{description, amount}] خصم كمية/تجاري بلا أثر على التكلفة
--   p_allocations: [{invoice_id, amount}] أو null = الفاتورة المرتبطة ثم الأقدم أولاً
-- ---------------------------------------------------------------------
create or replace function public.post_credit_note(
  p_supplier uuid, p_kind text, p_return_id uuid, p_invoice_id uuid, p_supplier_credit_no text, p_credit_date date,
  p_lines jsonb default null, p_allocations jsonb default null, p_notes text default null, p_client_ref uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_no text;
  v_rate numeric := public._vat_rate_for(p_supplier);
  r public.supplier_returns;
  e jsonb;
  g record;
  v_line numeric;
  v_sub numeric;
  v_vat numeric;
  v_used numeric;
  v_open numeric;
  it record;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if p_kind not in ('return', 'price', 'rebate') then
    raise exception 'نوع الإشعار غير صحيح';
  end if;
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtextextended('scn:' || p_client_ref::text, 0));
    select id into v_id from public.supplier_credit_notes where client_ref = p_client_ref;
    if v_id is not null then
      return v_id;
    end if;
  end if;
  perform public._lock_supplier(p_supplier);
  if p_invoice_id is not null and not exists (select 1 from public.supplier_invoices where id = p_invoice_id and supplier_id = p_supplier) then
    raise exception 'الفاتورة لا تخص هذا المورد';
  end if;
  if p_kind = 'return' then
    select * into r from public.supplier_returns where id = p_return_id for update;
    if r.id is null or r.supplier_id <> p_supplier then
      raise exception 'المرتجع لا يخص هذا المورد';
    end if;
    if r.status <> 'shipped' then
      raise exception 'الإشعار يصدر لمرتجع مشحون ولم يُشعَر به بعد';
    end if;
  end if;

  insert into public.supplier_credit_notes (supplier_id, kind, supplier_credit_no, credit_date, return_id, invoice_id,
                                            subtotal, vat_amount, total, notes, client_ref)
  values (p_supplier, p_kind, nullif(trim(p_supplier_credit_no), ''), coalesce(p_credit_date, current_date), p_return_id, p_invoice_id,
          0, 0, 0.01, nullif(trim(p_notes), ''), p_client_ref)
  returning id, cn_no into v_id, v_no;

  if p_kind = 'return' then
    insert into public.supplier_credit_note_items (credit_note_id, receipt_item_id, variant_id, qty, unit_amount, line_total, vat_rate, vat_amount)
    select v_id, ri.receipt_item_id, ri.variant_id, ri.qty, ri.unit_cost, round(ri.qty * ri.unit_cost, 2), v_rate,
           round(round(ri.qty * ri.unit_cost, 2) * v_rate / 100, 2)
      from public.supplier_return_items ri where ri.return_id = p_return_id;
    update public.supplier_returns set status = 'credited' where id = p_return_id;
  else
    if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
      raise exception 'الإشعار بدون بنود';
    end if;
    for e in select * from jsonb_array_elements(p_lines) loop
      if p_kind = 'price' then
        select gi.*, gr.supplier_id as sup into g
          from public.goods_receipt_items gi join public.goods_receipts gr on gr.id = gi.receipt_id
         where gi.id = (e ->> 'receipt_item_id')::uuid;
        if g.id is null or g.sup <> p_supplier then
          raise exception 'سطر الاستلام لا يخص هذا المورد';
        end if;
        if coalesce((e ->> 'qty')::integer, 0) <= 0 or (e ->> 'qty')::integer > g.qty
           or coalesce((e ->> 'unit_amount')::numeric, 0) <= 0 then
          raise exception 'كمية أو مبلغ تخفيض غير صحيح';
        end if;
        v_line := round((e ->> 'qty')::integer * (e ->> 'unit_amount')::numeric, 2);
        insert into public.supplier_credit_note_items (credit_note_id, receipt_item_id, variant_id, qty, unit_amount, line_total, vat_rate, vat_amount)
        values (v_id, g.id, g.variant_id, (e ->> 'qty')::integer, (e ->> 'unit_amount')::numeric, v_line, v_rate, round(v_line * v_rate / 100, 2));
        perform public._apply_cost_adjustment(g.variant_id, (e ->> 'qty')::integer, -v_line, 'credit_note', v_id);
      else
        v_line := round(coalesce((e ->> 'amount')::numeric, 0), 2);
        if v_line <= 0 or coalesce(trim(e ->> 'description'), '') = '' then
          raise exception 'أدخل وصف ومبلغ الخصم';
        end if;
        insert into public.supplier_credit_note_items (credit_note_id, description, qty, unit_amount, line_total, vat_rate, vat_amount)
        values (v_id, trim(e ->> 'description'), 1, v_line, v_line, v_rate, round(v_line * v_rate / 100, 2));
      end if;
    end loop;
  end if;

  select coalesce(sum(line_total), 0), coalesce(sum(vat_amount), 0) into v_sub, v_vat
    from public.supplier_credit_note_items where credit_note_id = v_id;
  if v_sub <= 0 then
    raise exception 'الإشعار بدون مبلغ';
  end if;
  update public.supplier_credit_notes set subtotal = v_sub, vat_amount = v_vat, total = v_sub + v_vat where id = v_id;
  perform public._ap_post(p_supplier, 'credit_note', v_id, coalesce(nullif(trim(p_supplier_credit_no), ''), v_no), v_sub + v_vat, 0,
                          v_no, coalesce(p_credit_date, current_date));

  -- التطبيق: صريح، أو الفاتورة المرتبطة أولاً ثم الأقدم
  v_used := 0;
  if p_allocations is null and p_invoice_id is not null then
    select total - settled_amount into v_open from public.supplier_invoices
     where id = p_invoice_id and status in ('posted', 'partially_paid');
    if coalesce(v_open, 0) > 0 then
      v_used := public._ap_allocate(p_supplier, 'credit_note', v_id, least(v_open, v_sub + v_vat),
                                    jsonb_build_array(jsonb_build_object('invoice_id', p_invoice_id, 'amount', least(v_open, v_sub + v_vat))));
    end if;
  end if;
  v_used := v_used + public._ap_allocate(p_supplier, 'credit_note', v_id, v_sub + v_vat - v_used, p_allocations);
  update public.supplier_credit_notes set allocated_amount = v_used where id = v_id;
  return v_id;
end;
$$;

-- إلغاء إشعار: يحرر توزيعاته ويعكس أثر التكلفة، ويعيد المرتجع لحالة «مشحون»
create or replace function public.void_credit_note(p_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  c public.supplier_credit_notes;
  a record;
  it record;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'السبب مطلوب';
  end if;
  select * into c from public.supplier_credit_notes where id = p_id;
  if c.id is null then
    raise exception 'الإشعار غير موجود';
  end if;
  perform public._lock_supplier(c.supplier_id);
  select * into c from public.supplier_credit_notes where id = p_id for update;
  if c.status = 'void' then
    raise exception 'الإشعار ملغى مسبقاً';
  end if;
  if exists (select 1 from public.supplier_refund_allocations where source_type = 'credit_note' and source_id = p_id) then
    raise exception 'استُرد جزء من هذا الإشعار نقداً — لا يمكن إلغاؤه';
  end if;
  for a in select * from public.supplier_allocations where source_type = 'credit_note' and source_id = p_id and voided_at is null for update loop
    update public.supplier_allocations set voided_at = now() where id = a.id;
    update public.supplier_invoices set settled_amount = settled_amount - a.amount where id = a.invoice_id;
    perform public._invoice_refresh_status(a.invoice_id);
  end loop;
  if c.kind = 'price' then
    for it in select * from public.supplier_credit_note_items where credit_note_id = p_id loop
      perform public._apply_cost_adjustment(it.variant_id, it.qty, it.line_total, 'credit_note_void', p_id);
    end loop;
  end if;
  if c.kind = 'return' then
    update public.supplier_returns set status = 'shipped' where id = c.return_id;
  end if;
  update public.supplier_credit_notes
     set status = 'void', allocated_amount = 0, void_reason = trim(p_reason), voided_by = auth.uid(), voided_at = now()
   where id = p_id;
  perform public._ap_post(c.supplier_id, 'void_credit_note', p_id, c.cn_no, 0, c.total, 'إلغاء: ' || trim(p_reason));
end;
$$;

-- ---------------------------------------------------------------------
-- استرداد من المورد: يستهلك الأرصدة الدائنة غير المطبقة (الأقدم أولاً)
-- ---------------------------------------------------------------------
create or replace function public.record_supplier_refund(
  p_supplier uuid, p_amount numeric, p_method public.ap_payment_method, p_reference text default null,
  p_received_at date default null, p_notes text default null, p_client_ref uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_no text;
  v_left numeric := p_amount;
  v_take numeric;
  v_shift uuid;
  v_mv uuid;
  src record;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if coalesce(p_amount, 0) <= 0 or p_method = 'opening' then
    raise exception 'مبلغ أو طريقة غير صحيحة';
  end if;
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtextextended('srf:' || p_client_ref::text, 0));
    select id into v_id from public.supplier_refunds where client_ref = p_client_ref;
    if v_id is not null then
      return v_id;
    end if;
  end if;
  perform public._lock_supplier(p_supplier);
  if p_amount > coalesce((select sum(amount - allocated_amount) from public.supplier_payments where supplier_id = p_supplier and not is_void), 0)
               + coalesce((select sum(total - allocated_amount) from public.supplier_credit_notes where supplier_id = p_supplier and status = 'posted'), 0) then
    raise exception 'الاسترداد أكبر من الرصيد الدائن غير المطبّق لدى المورد';
  end if;
  insert into public.supplier_refunds (supplier_id, amount, method, reference, received_at, notes, client_ref)
  values (p_supplier, p_amount, p_method, nullif(trim(p_reference), ''), coalesce(p_received_at, current_date), nullif(trim(p_notes), ''), p_client_ref)
  returning id, refund_no into v_id, v_no;

  if p_method = 'cash_drawer' then
    select id into v_shift from public.shifts where cashier_id = auth.uid() and status = 'open' for update;
    if v_shift is null then
      raise exception 'لا توجد لديك وردية مفتوحة للإيداع في الدرج';
    end if;
    insert into public.shift_cash_movements (shift_id, type, amount, reason)
    values (v_shift, 'in', p_amount, 'استرداد من مورد ' || v_no)
    returning id into v_mv;
    update public.supplier_refunds set shift_id = v_shift, shift_movement_id = v_mv where id = v_id;
  end if;

  for src in
    select 'payment' as t, id, amount - allocated_amount as free, created_at from public.supplier_payments
     where supplier_id = p_supplier and not is_void and amount > allocated_amount
    union all
    select 'credit_note', id, total - allocated_amount, created_at from public.supplier_credit_notes
     where supplier_id = p_supplier and status = 'posted' and total > allocated_amount
    order by created_at
  loop
    exit when v_left <= 0;
    v_take := least(v_left, src.free);
    insert into public.supplier_refund_allocations (refund_id, supplier_id, source_type, source_id, amount)
    values (v_id, p_supplier, src.t, src.id, v_take);
    if src.t = 'payment' then
      update public.supplier_payments set allocated_amount = allocated_amount + v_take where id = src.id;
    else
      update public.supplier_credit_notes set allocated_amount = allocated_amount + v_take where id = src.id;
    end if;
    v_left := v_left - v_take;
  end loop;
  perform public._ap_post(p_supplier, 'refund', v_id, v_no, 0, p_amount, nullif(trim(p_notes), ''), coalesce(p_received_at, current_date));
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- تكاليف الوصول
--   p_lines: [{cost_type, description, amount, vat_amount?, supplier_id, supplier_invoice_no?}]
--   p_method: value (بقيمة الاستلام) / qty (بالكمية) / manual (p_manual: [{receipt_item_id, amount}] مجموعه = الإجمالي)
-- ---------------------------------------------------------------------
create or replace function public.landed_cost_preview(p_receipts uuid[], p_total numeric, p_method text, p_manual jsonb default null)
returns table (receipt_item_id uuid, variant_id uuid, sku text, qty integer, basis numeric, amount numeric, per_unit numeric)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if p_method not in ('value', 'qty', 'manual') then
    raise exception 'طريقة توزيع غير صحيحة';
  end if;
  return query
  with lines as (
    select gi.id, gi.variant_id, v.sku, gi.qty,
           case p_method when 'value' then round(gi.qty * gi.unit_cost, 2) when 'qty' then gi.qty::numeric
                else coalesce((select sum((e ->> 'amount')::numeric) from jsonb_array_elements(coalesce(p_manual, '[]')) e
                                where (e ->> 'receipt_item_id')::uuid = gi.id), 0) end as basis,
           row_number() over (order by gi.id) as rn, count(*) over () as n
      from public.goods_receipt_items gi join public.product_variants v on v.id = gi.variant_id
     where gi.receipt_id = any(p_receipts)
  ),
  tot as (select sum(basis) as b from lines),
  shares as (
    select l.*, case when p_method = 'manual' then l.basis
                     when (select b from tot) > 0 then round(p_total * l.basis / (select b from tot), 2) else 0 end as share
      from lines l
  )
  -- التقريب: آخر سطر يأخذ الفرق حتى يطابق المجموع الإجمالي حرفياً
  select s.id, s.variant_id, s.sku, s.qty, s.basis,
         case when s.rn = s.n and p_method <> 'manual' then p_total - coalesce(sum(s.share) filter (where s.rn < s.n) over (), 0) else s.share end,
         round(case when s.rn = s.n and p_method <> 'manual' then p_total - coalesce(sum(s.share) filter (where s.rn < s.n) over (), 0) else s.share end / s.qty, 4)
    from shares s order by s.rn;
end;
$$;

create or replace function public.post_landed_cost(
  p_receipts uuid[], p_lines jsonb, p_method text, p_manual jsonb default null, p_notes text default null, p_client_ref uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_no text;
  v_total numeric;
  e jsonb;
  v_line uuid;
  v_vat numeric;
  a record;
  grp record;
  v_inv uuid;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtextextended('lcv:' || p_client_ref::text, 0));
    select id into v_id from public.landed_cost_vouchers where client_ref = p_client_ref;
    if v_id is not null then
      return v_id;
    end if;
  end if;
  if p_receipts is null or cardinality(p_receipts) = 0
     or exists (select 1 from unnest(p_receipts) x where not exists (select 1 from public.goods_receipts where id = x)) then
    raise exception 'اختر سندات استلام صحيحة';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'أدخل بنود التكاليف';
  end if;
  select sum(round((x ->> 'amount')::numeric, 2)) into v_total from jsonb_array_elements(p_lines) x;
  if coalesce(v_total, 0) <= 0 or exists (select 1 from jsonb_array_elements(p_lines) x
                                           where coalesce((x ->> 'amount')::numeric, 0) <= 0 or (x ->> 'supplier_id') is null) then
    raise exception 'كل بند يحتاج مبلغاً ومورداً (شركة الشحن، الجمارك…)';
  end if;
  if p_method = 'manual' and coalesce((select sum((m ->> 'amount')::numeric) from jsonb_array_elements(coalesce(p_manual, '[]')) m), 0) <> v_total then
    raise exception 'مجموع التوزيع اليدوي لا يساوي إجمالي التكاليف (%)', v_total;
  end if;

  insert into public.landed_cost_vouchers (method, total_amount, notes, client_ref)
  values (p_method, v_total, nullif(trim(p_notes), ''), p_client_ref)
  returning id, lc_no into v_id, v_no;

  for e in select * from jsonb_array_elements(p_lines) loop
    v_vat := coalesce((e ->> 'vat_amount')::numeric,
                      round(round((e ->> 'amount')::numeric, 2) * public._vat_rate_for((e ->> 'supplier_id')::uuid) / 100, 2));
    insert into public.landed_cost_lines (voucher_id, cost_type, description, supplier_id, supplier_invoice_no, amount, vat_amount)
    values (v_id, coalesce(e ->> 'cost_type', 'other'), nullif(trim(e ->> 'description'), ''), (e ->> 'supplier_id')::uuid,
            nullif(trim(e ->> 'supplier_invoice_no'), ''), round((e ->> 'amount')::numeric, 2), v_vat);
  end loop;

  -- التوزيع على سطور الاستلام وتعديل التكلفة
  for a in select * from public.landed_cost_preview(p_receipts, v_total, p_method, p_manual) loop
    insert into public.landed_cost_allocations (voucher_id, receipt_item_id, variant_id, qty, basis, amount)
    values (v_id, a.receipt_item_id, a.variant_id, a.qty, a.basis, a.amount);
    perform public._apply_cost_adjustment(a.variant_id, a.qty, a.amount, 'landed_cost', v_id);
  end loop;
  if (select sum(amount) from public.landed_cost_allocations where voucher_id = v_id) <> v_total then
    raise exception 'التوزيع لا يطابق الإجمالي';
  end if;

  -- فاتورة مصروف مستحقة لكل مورد تكلفة (ورقم فاتورته)
  for grp in
    select supplier_id, supplier_invoice_no, sum(amount) as sub, sum(vat_amount) as vat
      from public.landed_cost_lines where voucher_id = v_id group by 1, 2
  loop
    perform public._lock_supplier(grp.supplier_id);
    insert into public.supplier_invoices (supplier_id, kind, status, supplier_invoice_no, invoice_date, due_date, payment_terms,
                                          subtotal, vat_amount, total, notes, match_status, posted_by, posted_at)
    values (grp.supplier_id, 'expense', 'posted', grp.supplier_invoice_no, current_date,
            current_date + (select payment_terms_days from public.suppliers where id = grp.supplier_id), 'credit',
            grp.sub, grp.vat, grp.sub + grp.vat, 'تكاليف وصول ' || v_no, 'not_required', auth.uid(), now())
    returning id into v_inv;
    insert into public.supplier_invoice_items (invoice_id, description, qty, unit_cost, line_total, vat_rate, vat_amount)
    select v_inv, coalesce(l.description, l.cost_type), 1, l.amount, l.amount,
           case when l.amount > 0 then round(l.vat_amount / l.amount * 100, 2) else 0 end, l.vat_amount
      from public.landed_cost_lines l
     where l.voucher_id = v_id and l.supplier_id = grp.supplier_id and l.supplier_invoice_no is not distinct from grp.supplier_invoice_no;
    update public.landed_cost_lines set expense_invoice_id = v_inv
     where voucher_id = v_id and supplier_id = grp.supplier_id and supplier_invoice_no is not distinct from grp.supplier_invoice_no;
    perform public._ap_post(grp.supplier_id, 'invoice', v_inv, coalesce(grp.supplier_invoice_no, v_no), 0, grp.sub + grp.vat,
                            'تكاليف وصول ' || v_no);
  end loop;
  return v_id;
end;
$$;

create or replace function public.void_landed_cost(p_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v public.landed_cost_vouchers;
  a record;
  li record;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'السبب مطلوب';
  end if;
  select * into v from public.landed_cost_vouchers where id = p_id for update;
  if v.id is null or v.status = 'void' then
    raise exception 'السند غير موجود أو ملغى';
  end if;
  if exists (select 1 from public.landed_cost_lines l join public.supplier_invoices i on i.id = l.expense_invoice_id
              where l.voucher_id = p_id and i.settled_amount > 0) then
    raise exception 'سُدد جزء من فواتير هذه التكاليف — ألغِ الدفعات أولاً';
  end if;
  for a in select * from public.landed_cost_allocations where voucher_id = p_id loop
    perform public._apply_cost_adjustment(a.variant_id, a.qty, -a.amount, 'landed_cost_void', p_id);
  end loop;
  for li in select distinct expense_invoice_id from public.landed_cost_lines where voucher_id = p_id and expense_invoice_id is not null loop
    perform public.void_supplier_invoice(li.expense_invoice_id, 'إلغاء تكاليف وصول ' || v.lc_no || ': ' || trim(p_reason));
  end loop;
  update public.landed_cost_vouchers set status = 'void', void_reason = trim(p_reason), voided_by = auth.uid(), voided_at = now()
   where id = p_id;
end;
$$;

-- ---------------------------------------------------------------------
-- الصلاحيات
-- ---------------------------------------------------------------------
alter table public.supplier_returns enable row level security;
alter table public.supplier_return_items enable row level security;
alter table public.supplier_credit_notes enable row level security;
alter table public.supplier_credit_note_items enable row level security;
alter table public.supplier_refunds enable row level security;
alter table public.supplier_refund_allocations enable row level security;
alter table public.landed_cost_vouchers enable row level security;
alter table public.landed_cost_lines enable row level security;
alter table public.landed_cost_allocations enable row level security;

revoke all on public.supplier_returns, public.supplier_return_items, public.supplier_credit_notes, public.supplier_credit_note_items,
  public.supplier_refunds, public.supplier_refund_allocations, public.landed_cost_vouchers, public.landed_cost_lines,
  public.landed_cost_allocations from anon, authenticated;
revoke usage on sequence public.supplier_return_seq, public.supplier_credit_seq, public.supplier_refund_seq, public.landed_cost_seq from anon;
grant select on public.supplier_returns, public.supplier_return_items, public.supplier_credit_notes, public.supplier_credit_note_items,
  public.supplier_refunds, public.supplier_refund_allocations, public.landed_cost_vouchers, public.landed_cost_lines,
  public.landed_cost_allocations to authenticated;

create policy supplier_returns_select on public.supplier_returns for select to authenticated using (public.is_manager());
create policy supplier_return_items_select on public.supplier_return_items for select to authenticated using (public.is_manager());
create policy supplier_credit_notes_select on public.supplier_credit_notes for select to authenticated using (public.is_manager());
create policy supplier_credit_note_items_select on public.supplier_credit_note_items for select to authenticated using (public.is_manager());
create policy supplier_refunds_select on public.supplier_refunds for select to authenticated using (public.is_manager());
create policy supplier_refund_allocations_select on public.supplier_refund_allocations for select to authenticated using (public.is_manager());
create policy landed_cost_vouchers_select on public.landed_cost_vouchers for select to authenticated using (public.is_manager());
create policy landed_cost_lines_select on public.landed_cost_lines for select to authenticated using (public.is_manager());
create policy landed_cost_allocations_select on public.landed_cost_allocations for select to authenticated using (public.is_manager());

create trigger supplier_returns_audit after insert or update or delete on public.supplier_returns
  for each row execute function public.audit_trigger();
create trigger supplier_credit_notes_audit after insert or update or delete on public.supplier_credit_notes
  for each row execute function public.audit_trigger();
create trigger supplier_refunds_audit after insert or update or delete on public.supplier_refunds
  for each row execute function public.audit_trigger();
create trigger landed_cost_vouchers_audit after insert or update or delete on public.landed_cost_vouchers
  for each row execute function public.audit_trigger();

revoke execute on function
  public.create_supplier_return(uuid, uuid, jsonb, text, text, uuid), public.approve_supplier_return(uuid),
  public.cancel_supplier_return(uuid, text), public.ship_supplier_return(uuid, uuid),
  public.post_credit_note(uuid, text, uuid, uuid, text, date, jsonb, jsonb, text, uuid), public.void_credit_note(uuid, text),
  public.record_supplier_refund(uuid, numeric, public.ap_payment_method, text, date, text, uuid),
  public.landed_cost_preview(uuid[], numeric, text, jsonb), public.post_landed_cost(uuid[], jsonb, text, jsonb, text, uuid),
  public.void_landed_cost(uuid, text)
from public, anon;
grant execute on function
  public.create_supplier_return(uuid, uuid, jsonb, text, text, uuid), public.approve_supplier_return(uuid),
  public.cancel_supplier_return(uuid, text), public.ship_supplier_return(uuid, uuid),
  public.post_credit_note(uuid, text, uuid, uuid, text, date, jsonb, jsonb, text, uuid), public.void_credit_note(uuid, text),
  public.record_supplier_refund(uuid, numeric, public.ap_payment_method, text, date, text, uuid),
  public.landed_cost_preview(uuid[], numeric, text, jsonb), public.post_landed_cost(uuid[], jsonb, text, jsonb, text, uuid),
  public.void_landed_cost(uuid, text)
to authenticated;

-- ترقية مشروع قائم: نفّذ هذا الملف مرة واحدة في SQL Editor (مولَّد من supabase/migrations/0018_purchase_documents.sql)
-- لا تنفذه على مشروع جديد — المشروع الجديد يستخدم 01_all_migrations.sql الذي يتضمنه.
begin;
-- =====================================================================
-- 0018 مستندات الشراء (PR #9 — المرحلة 2)
--   • الاستلام الجزئي: سند استلام (GRN) لكل دفعة واصلة، لا يُعدَّل بعد ترحيله
--     المخزون يدخل موقع أمر الشراء، والتكلفة المتوسطة تتحدث مؤقتاً بسعر أمر الشراء
--   • فاتورة المورد مرتبطة بسطور الاستلام + مطابقة ثلاثية (أمر الشراء ↔ الاستلام ↔ الفاتورة)
--     سماح فرق السعر من الإعدادات (افتراضي 2%). المفوتر أكثر من المستلم ممنوع دائماً
--   • ترحيل الفاتورة ينشئ الدَّين في دفتر المورد، ويسوّي فرق السعر عن سعر أمر الشراء:
--     نصيب الكمية الباقية في المخزون يعدّل المتوسط، ونصيب ما بيع قبل الفاتورة = فرق تكلفة بتاريخ الترحيل
--   • طريقة السداد: نقدي (دفعة كاملة عند الترحيل) / آجل / جزئي
--   • شراء مباشر بدون أمر شراء: ينشئ أمر الشراء والاستلام والفاتورة في عملية واحدة
--   • المرفقات في مخزن ملفات خاص للمدير فقط
--   • توافق عكسي: receive_purchase بنفس التوقيع (يستلم كل المتبقي)، والكتابة القديمة على أوامر الشراء كما هي
-- =====================================================================

-- القيم الجديدة تُستخدم داخل الدوال فقط (لا فهارس ولا قيود تعتمد عليها في نفس المعاملة)
alter type public.purchase_status add value if not exists 'partially_received' after 'ordered';
alter type public.purchase_status add value if not exists 'closed' after 'received';

alter table public.store_settings
  add column purchase_match_tolerance_pct numeric(5,2) not null default 2.00
    check (purchase_match_tolerance_pct between 0 and 50);

alter table public.purchase_orders
  add column expected_at date,
  add column approved_by uuid references public.profiles (id),
  add column approved_at timestamptz,
  add column close_reason text,
  add column client_ref uuid unique;

alter table public.purchase_items
  add column qty_received integer not null default 0 check (qty_received >= 0),
  add column qty_invoiced integer not null default 0 check (qty_invoiced >= 0),
  add column qty_returned integer not null default 0 check (qty_returned >= 0),
  add constraint purchase_items_received_le_qty check (qty_received <= qty),
  add constraint purchase_items_invoiced_le_received check (qty_invoiced <= qty_received),
  add constraint purchase_items_returned_le_received check (qty_returned <= qty_received);

-- ---------------------------------------------------------------------
-- سندات الاستلام
-- ---------------------------------------------------------------------
create sequence public.goods_receipt_seq start 1;

create table public.goods_receipts (
  id uuid primary key default gen_random_uuid(),
  grn_no text not null unique
    default 'GRN-' || to_char(now() at time zone 'Asia/Riyadh', 'YY') || lpad(nextval('public.goods_receipt_seq')::text, 5, '0'),
  purchase_order_id uuid not null references public.purchase_orders (id),
  supplier_id uuid not null references public.suppliers (id),
  location_id uuid references public.locations (id),
  notes text,
  is_historical boolean not null default false,     -- أوامر شراء استُلمت قبل هذه الترقية
  client_ref uuid unique,
  received_by uuid references public.profiles (id) default auth.uid(),
  received_at timestamptz not null default clock_timestamp()
);
create index goods_receipts_po_idx on public.goods_receipts (purchase_order_id);

create table public.goods_receipt_items (
  id uuid primary key default gen_random_uuid(),
  receipt_id uuid not null references public.goods_receipts (id) on delete cascade,
  purchase_item_id uuid not null references public.purchase_items (id),
  variant_id uuid not null references public.product_variants (id),
  qty integer not null check (qty > 0),
  unit_cost numeric(12,2) not null check (unit_cost >= 0),     -- سعر أمر الشراء وقت الاستلام (قبل الضريبة)
  qty_invoiced integer not null default 0 check (qty_invoiced >= 0),
  qty_returned integer not null default 0 check (qty_returned >= 0),
  constraint gri_invoiced_le_qty check (qty_invoiced <= qty),
  constraint gri_returned_le_qty check (qty_returned <= qty)
);
create index goods_receipt_items_receipt_idx on public.goods_receipt_items (receipt_id);
create index goods_receipt_items_pi_idx on public.goods_receipt_items (purchase_item_id);

-- أوامر الشراء المستلمة سابقاً: سند استلام تاريخي واحد، مفوتر بالكامل (لا دَين ولا تعديل تكلفة)
update public.purchase_items pi set qty_received = pi.qty, qty_invoiced = pi.qty
  from public.purchase_orders po where po.id = pi.purchase_id and po.status = 'received';
insert into public.goods_receipts (purchase_order_id, supplier_id, location_id, notes, is_historical, received_by, received_at)
select po.id, po.supplier_id, po.location_id, 'استلام قبل ترقية المشتريات', true, po.received_by, coalesce(po.received_at, po.updated_at)
  from public.purchase_orders po where po.status = 'received';
insert into public.goods_receipt_items (receipt_id, purchase_item_id, variant_id, qty, unit_cost, qty_invoiced)
select gr.id, pi.id, pi.variant_id, pi.qty, pi.unit_cost, pi.qty
  from public.goods_receipts gr join public.purchase_items pi on pi.purchase_id = gr.purchase_order_id
 where gr.is_historical;

-- ---------------------------------------------------------------------
-- فواتير المورد: ربط بأمر الشراء + بنود
-- ---------------------------------------------------------------------
alter table public.supplier_invoices
  add column purchase_order_id uuid references public.purchase_orders (id),
  add column location_id uuid references public.locations (id),
  add column match_status text check (match_status in ('not_required', 'matched', 'within_tolerance', 'override')),
  add column match_override_by uuid references public.profiles (id),
  add column match_override_reason text;

create table public.supplier_invoice_items (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.supplier_invoices (id) on delete cascade,
  receipt_item_id uuid references public.goods_receipt_items (id),     -- سطر بضاعة
  variant_id uuid references public.product_variants (id),
  description text,                                                    -- سطر مصروف (شحن، خدمة…)
  qty integer not null default 1 check (qty > 0),
  unit_cost numeric(12,2) not null check (unit_cost >= 0),
  po_unit_cost numeric(12,2),
  line_total numeric(12,2) not null check (line_total >= 0),
  vat_rate numeric(5,2) not null default 0,
  vat_amount numeric(12,2) not null default 0 check (vat_amount >= 0),
  constraint sii_stock_or_expense check ((receipt_item_id is not null and variant_id is not null) or
                                         (receipt_item_id is null and coalesce(trim(description), '') <> ''))
);
create index supplier_invoice_items_invoice_idx on public.supplier_invoice_items (invoice_id);
create index supplier_invoice_items_gri_idx on public.supplier_invoice_items (receipt_item_id);

-- ---------------------------------------------------------------------
-- تعديلات التكلفة (فرق سعر الفاتورة هنا، وتكاليف الوصول والإشعارات السعرية في 0019)
-- ---------------------------------------------------------------------
create table public.cost_adjustments (
  id bigint generated always as identity primary key,
  variant_id uuid not null references public.product_variants (id),
  source_type text not null check (source_type in ('invoice_price', 'invoice_void', 'landed_cost', 'credit_note')),
  source_id uuid not null,
  qty_basis integer not null check (qty_basis > 0),        -- الكمية التي يخصها التعديل
  qty_in_stock integer not null check (qty_in_stock >= 0), -- منها ما زال في المخزون وقت الترحيل
  total_delta numeric(12,2) not null,
  stock_delta numeric(12,2) not null,                      -- يدخل متوسط التكلفة
  variance_delta numeric(12,2) not null,                   -- فرق تكلفة (نصيب ما بيع)
  cost_before numeric(12,2) not null,
  cost_after numeric(12,2) not null,
  posted_by uuid references public.profiles (id) default auth.uid(),
  posted_at timestamptz not null default clock_timestamp()
);
create index cost_adjustments_posted_idx on public.cost_adjustments (posted_at);
create index cost_adjustments_source_idx on public.cost_adjustments (source_type, source_id);

-- ---------------------------------------------------------------------
-- المرفقات (مخزن خاص)
-- ---------------------------------------------------------------------
create table public.purchase_attachments (
  id uuid primary key default gen_random_uuid(),
  owner_type text not null check (owner_type in ('purchase_order', 'goods_receipt', 'supplier_invoice', 'supplier_payment',
                                                 'supplier_return', 'credit_note', 'landed_cost')),
  owner_id uuid not null,
  file_path text not null unique,
  file_name text not null,
  mime_type text not null,
  size_bytes integer not null check (size_bytes > 0 and size_bytes <= 10485760),
  uploaded_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now()
);
create index purchase_attachments_owner_idx on public.purchase_attachments (owner_type, owner_id);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('purchase-docs', 'purchase-docs', false, 10485760, array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;
create policy "purchase docs read" on storage.objects for select to authenticated
  using (bucket_id = 'purchase-docs' and public.is_manager());
create policy "purchase docs insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'purchase-docs' and public.is_manager());

-- ---------------------------------------------------------------------
-- حماية أمر الشراء: الحالات الناتجة عن الاستلام لا تُضبط إلا من الدوال، ولا يُلغى بعد أي استلام
-- (الكتابة القديمة على المسودة والمرسل تبقى كما هي)
-- ---------------------------------------------------------------------
create or replace function public.purchase_order_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_rpc boolean := coalesce(current_setting('app.po_rpc', true), '') = 'on';
begin
  if v_rpc then
    return new;
  end if;
  if new.status::text in ('partially_received', 'received', 'closed') and new.status is distinct from old.status then
    raise exception 'حالة أمر الشراء تتغير بالاستلام فقط';
  end if;
  if new.status::text = 'cancelled' and old.status::text <> 'cancelled'
     and exists (select 1 from public.purchase_items where purchase_id = new.id and qty_received > 0) then
    raise exception 'لا يمكن إلغاء أمر شراء استُلم منه جزء — أغلق المتبقي بدلاً من ذلك';
  end if;
  return new;
end;
$$;
create trigger purchase_orders_guard before update on public.purchase_orders
  for each row execute function public.purchase_order_guard();

create or replace function public.purchase_item_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('app.po_rpc', true), '') = 'on' then
    return coalesce(new, old);
  end if;
  if tg_op in ('UPDATE', 'DELETE') and (old.qty_received > 0 or old.qty_invoiced > 0) then
    raise exception 'لا يمكن تعديل سطر استُلم منه — أنشئ أمر شراء جديداً للفرق';
  end if;
  if tg_op = 'UPDATE' and (new.qty_received <> old.qty_received or new.qty_invoiced <> old.qty_invoiced
                           or new.qty_returned <> old.qty_returned) then
    raise exception 'الكميات المستلمة والمفوترة تتغير من المستندات فقط';
  end if;
  if tg_op = 'INSERT' and (new.qty_received <> 0 or new.qty_invoiced <> 0 or new.qty_returned <> 0) then
    raise exception 'الكميات المستلمة والمفوترة تتغير من المستندات فقط';
  end if;
  return coalesce(new, old);
end;
$$;
create trigger purchase_items_guard before insert or update or delete on public.purchase_items
  for each row execute function public.purchase_item_guard();

-- ---------------------------------------------------------------------
-- تعديل التكلفة: نصيب الموجود يدخل المتوسط، ونصيب ما بيع = فرق تكلفة
-- ---------------------------------------------------------------------
create or replace function public._apply_cost_adjustment(
  p_variant uuid, p_qty_basis integer, p_delta numeric, p_source_type text, p_source uuid
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_on_hand integer;
  v_cost numeric;
  v_rem integer;
  v_stock numeric;
  v_new numeric;
begin
  if coalesce(p_delta, 0) = 0 or coalesce(p_qty_basis, 0) <= 0 then
    return;
  end if;
  select greatest(v.stock_qty, 0), coalesce(c.cost_price, 0) into v_on_hand, v_cost
    from public.product_variants v left join public.variant_costs c on c.variant_id = v.id
   where v.id = p_variant for update of v;
  v_rem := least(p_qty_basis, v_on_hand);
  v_stock := round(p_delta * v_rem / p_qty_basis, 2);
  v_new := v_cost;
  if v_on_hand > 0 and v_stock <> 0 then
    v_new := round((v_on_hand * v_cost + v_stock) / v_on_hand, 2);
    if v_new < 0 then
      -- لا تكلفة سالبة: الفائض يذهب لفرق التكلفة
      v_stock := -v_on_hand * v_cost;
      v_new := 0;
    end if;
    insert into public.variant_costs (variant_id, cost_price) values (p_variant, v_new)
    on conflict (variant_id) do update set cost_price = excluded.cost_price, updated_at = now();
  else
    v_stock := 0;
  end if;
  insert into public.cost_adjustments (variant_id, source_type, source_id, qty_basis, qty_in_stock, total_delta,
                                       stock_delta, variance_delta, cost_before, cost_after)
  values (p_variant, p_source_type, p_source, p_qty_basis, v_rem, p_delta, v_stock, p_delta - v_stock, v_cost, v_new);
end;
$$;

-- ---------------------------------------------------------------------
-- أوامر الشراء: اعتماد، إغلاق المتبقي
-- ---------------------------------------------------------------------
create or replace function public.approve_purchase_order(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  po public.purchase_orders;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  select * into po from public.purchase_orders where id = p_id for update;
  if po.id is null or po.status <> 'draft' then
    raise exception 'أمر الشراء ليس مسودة';
  end if;
  if not exists (select 1 from public.purchase_items where purchase_id = p_id) then
    raise exception 'أمر الشراء لا يحتوي أصنافاً';
  end if;
  update public.purchase_orders set status = 'ordered', approved_by = auth.uid(), approved_at = now() where id = p_id;
end;
$$;

create or replace function public.close_purchase_order(p_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  po public.purchase_orders;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'السبب مطلوب';
  end if;
  select * into po from public.purchase_orders where id = p_id for update;
  if po.id is null or po.status::text <> 'partially_received' then
    raise exception 'يُغلق المتبقي لأمر شراء مستلم جزئياً فقط (غير المستلم: ألغه)';
  end if;
  perform set_config('app.po_rpc', 'on', true);
  update public.purchase_orders set status = 'closed', close_reason = trim(p_reason) where id = p_id;
  perform set_config('app.po_rpc', '', true);
end;
$$;

-- ---------------------------------------------------------------------
-- الاستلام الجزئي. p_items: [{purchase_item_id | variant_id, qty}] أو null = كل المتبقي
--   المدير، أو موظف موقع الاستلام (الكمية فقط)
-- ---------------------------------------------------------------------
create or replace function public.receive_goods(
  p_po uuid, p_items jsonb default null, p_notes text default null, p_client_ref uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  po public.purchase_orders;
  v_loc uuid;
  v_grn uuid;
  v_grn_no text;
  r record;
  v_qty integer;
  v_old_qty integer;
  v_old_cost numeric;
  v_total integer := 0;
begin
  if not public.is_staff() then
    raise exception 'غير مصرح';
  end if;
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtextextended('grn:' || p_client_ref::text, 0));
    select id into v_grn from public.goods_receipts where client_ref = p_client_ref;
    if v_grn is not null then
      return v_grn;
    end if;
  end if;
  select * into po from public.purchase_orders where id = p_po for update;
  if po.id is null then
    raise exception 'أمر الشراء غير موجود';
  end if;
  if po.status::text not in ('draft', 'ordered', 'partially_received') then
    raise exception 'لا يمكن استلام أمر شراء بحالة %', po.status;
  end if;
  v_loc := coalesce(po.location_id, public._default_location());
  if not public.is_manager() and public._my_location() is distinct from v_loc then
    raise exception 'الاستلام لموظفي موقع الاستلام أو المدير فقط';
  end if;
  if not exists (select 1 from public.purchase_items where purchase_id = p_po) then
    raise exception 'أمر الشراء لا يحتوي أصنافاً';
  end if;

  perform set_config('app.po_rpc', 'on', true);
  insert into public.goods_receipts (purchase_order_id, supplier_id, location_id, notes, client_ref)
  values (p_po, po.supplier_id, v_loc, nullif(trim(p_notes), ''), p_client_ref)
  returning id, grn_no into v_grn, v_grn_no;

  for r in
    select pi.*,
           case when p_items is null then pi.qty - pi.qty_received
                else coalesce((select sum((e ->> 'qty')::integer) from jsonb_array_elements(p_items) e
                                where (e ->> 'purchase_item_id')::uuid = pi.id
                                   or ((e ->> 'purchase_item_id') is null and (e ->> 'variant_id')::uuid = pi.variant_id)), 0) end as want
      from public.purchase_items pi where pi.purchase_id = p_po
     order by pi.id
     for update of pi
  loop
    v_qty := r.want;
    continue when v_qty = 0;
    if v_qty < 0 then
      raise exception 'كمية غير صحيحة';
    end if;
    if v_qty > r.qty - r.qty_received then
      raise exception 'الكمية المستلمة أكبر من المتبقي في أمر الشراء (المتبقي %)', r.qty - r.qty_received;
    end if;

    -- المتوسط المرجّح بسعر أمر الشراء (مؤقتاً حتى الفاتورة)
    select greatest(v.stock_qty, 0), coalesce(c.cost_price, 0) into v_old_qty, v_old_cost
      from public.product_variants v left join public.variant_costs c on c.variant_id = v.id
     where v.id = r.variant_id for update of v;
    insert into public.variant_costs (variant_id, cost_price)
    values (r.variant_id, case when v_old_qty + v_qty > 0
                               then round((v_old_qty * v_old_cost + v_qty * r.unit_cost) / (v_old_qty + v_qty), 2)
                               else r.unit_cost end)
    on conflict (variant_id) do update set cost_price = excluded.cost_price, updated_at = now();

    perform public._move_stock(r.variant_id, v_qty, 'purchase', p_po, v_grn_no, false);
    insert into public.goods_receipt_items (receipt_id, purchase_item_id, variant_id, qty, unit_cost)
    values (v_grn, r.id, r.variant_id, v_qty, r.unit_cost);
    update public.purchase_items set qty_received = qty_received + v_qty where id = r.id;
    v_total := v_total + v_qty;
  end loop;

  if v_total = 0 then
    raise exception 'لم يتم تحديد كميات للاستلام';
  end if;
  if p_items is not null and exists (
    select 1 from jsonb_array_elements(p_items) e
     where not exists (select 1 from public.purchase_items pi where pi.purchase_id = p_po
                         and (pi.id = (e ->> 'purchase_item_id')::uuid
                              or ((e ->> 'purchase_item_id') is null and pi.variant_id = (e ->> 'variant_id')::uuid)))) then
    raise exception 'صنف غير موجود في أمر الشراء';
  end if;

  if exists (select 1 from public.purchase_items where purchase_id = p_po and qty_received < qty) then
    update public.purchase_orders set status = 'partially_received' where id = p_po;
  else
    update public.purchase_orders set status = 'received', received_at = now(), received_by = auth.uid() where id = p_po;
  end if;
  perform set_config('app.po_rpc', '', true);
  return v_grn;
end;
$$;

-- التوافق العكسي: نفس التوقيع والسلوك (استلام كل المتبقي)؛ الكود الحالي يستمر في العمل
create or replace function public.receive_purchase(p_purchase_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  perform public.receive_goods(p_purchase_id, null, null, null);
end;
$$;

-- ---------------------------------------------------------------------
-- الفاتورة: حفظ مسودة، مطابقة، ترحيل، إلغاء
--   p_lines: [{receipt_item_id, qty, unit_cost}] للبضاعة، أو [{description, amount}] للمصروف
-- ---------------------------------------------------------------------
create or replace function public._vat_rate_for(p_supplier uuid)
returns numeric language sql stable security definer set search_path = public as $$
  select case when (select vat_registered from public.suppliers where id = p_supplier)
              then (select vat_rate from public.store_settings where id = 1) else 0 end
$$;

create or replace function public.save_supplier_invoice(
  p_id uuid, p_supplier uuid, p_po uuid, p_supplier_invoice_no text, p_invoice_date date, p_due_date date,
  p_payment_terms public.ap_payment_terms, p_lines jsonb, p_notes text default null, p_client_ref uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  s public.suppliers;
  po public.purchase_orders;
  v_id uuid := p_id;
  v_rate numeric;
  e jsonb;
  gri record;
  v_qty integer;
  v_cost numeric;
  v_line numeric;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'الفاتورة بدون بنود';
  end if;
  if v_id is null and p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtextextended('sin:' || p_client_ref::text, 0));
    select id into v_id from public.supplier_invoices where client_ref = p_client_ref;
    if v_id is not null and (select status from public.supplier_invoices where id = v_id) <> 'draft' then
      return v_id;
    end if;
  end if;
  s := public._lock_supplier(p_supplier);
  if p_po is not null then
    select * into po from public.purchase_orders where id = p_po;
    if po.id is null or po.supplier_id <> p_supplier then
      raise exception 'أمر الشراء لا يخص هذا المورد';
    end if;
  end if;
  v_rate := public._vat_rate_for(p_supplier);

  if v_id is null then
    insert into public.supplier_invoices (supplier_id, kind, supplier_invoice_no, invoice_date, due_date, payment_terms,
                                          purchase_order_id, location_id, notes, client_ref)
    values (p_supplier, case when p_po is null and not exists (select 1 from jsonb_array_elements(p_lines) x where x ? 'receipt_item_id')
                             then 'expense' else 'purchase' end::public.ap_invoice_kind,
            nullif(trim(p_supplier_invoice_no), ''), coalesce(p_invoice_date, current_date),
            coalesce(p_due_date, coalesce(p_invoice_date, current_date) + s.payment_terms_days),
            coalesce(p_payment_terms, (case when s.payment_terms_days > 0 then 'credit' else 'cash' end)::public.ap_payment_terms),
            p_po, po.location_id, nullif(trim(p_notes), ''), p_client_ref)
    returning id into v_id;
  else
    perform 1 from public.supplier_invoices where id = v_id and supplier_id = p_supplier and status = 'draft' for update;
    if not found then
      raise exception 'الفاتورة غير موجودة أو ليست مسودة';
    end if;
    update public.supplier_invoices
       set supplier_invoice_no = nullif(trim(p_supplier_invoice_no), ''), invoice_date = coalesce(p_invoice_date, invoice_date),
           due_date = coalesce(p_due_date, coalesce(p_invoice_date, invoice_date) + s.payment_terms_days),
           payment_terms = coalesce(p_payment_terms, payment_terms), purchase_order_id = p_po,
           location_id = coalesce(po.location_id, location_id), notes = nullif(trim(p_notes), '')
     where id = v_id;
    delete from public.supplier_invoice_items where invoice_id = v_id;
  end if;

  for e in select * from jsonb_array_elements(p_lines) loop
    if e ? 'receipt_item_id' then
      select gi.*, gr.supplier_id as sup, gr.purchase_order_id as po_id into gri
        from public.goods_receipt_items gi join public.goods_receipts gr on gr.id = gi.receipt_id
       where gi.id = (e ->> 'receipt_item_id')::uuid;
      if gri.id is null or gri.sup <> p_supplier then
        raise exception 'سطر الاستلام لا يخص هذا المورد';
      end if;
      if p_po is not null and gri.po_id <> p_po then
        raise exception 'سطر الاستلام من أمر شراء آخر';
      end if;
      v_qty := coalesce((e ->> 'qty')::integer, 0);
      v_cost := coalesce((e ->> 'unit_cost')::numeric, gri.unit_cost);
      if v_qty <= 0 or v_cost < 0 then
        raise exception 'كمية أو سعر غير صحيح';
      end if;
      v_line := round(v_qty * v_cost, 2);
      insert into public.supplier_invoice_items (invoice_id, receipt_item_id, variant_id, qty, unit_cost, po_unit_cost,
                                                 line_total, vat_rate, vat_amount)
      values (v_id, gri.id, gri.variant_id, v_qty, v_cost, gri.unit_cost, v_line, v_rate, round(v_line * v_rate / 100, 2));
    else
      v_line := round(coalesce((e ->> 'amount')::numeric, 0), 2);
      if v_line <= 0 or coalesce(trim(e ->> 'description'), '') = '' then
        raise exception 'أدخل وصف ومبلغ سطر المصروف';
      end if;
      insert into public.supplier_invoice_items (invoice_id, description, qty, unit_cost, line_total, vat_rate, vat_amount)
      values (v_id, trim(e ->> 'description'), 1, v_line, v_line,
              case when coalesce((e ->> 'vat')::boolean, true) then v_rate else 0 end,
              case when coalesce((e ->> 'vat')::boolean, true) then round(v_line * v_rate / 100, 2) else 0 end);
    end if;
  end loop;

  update public.supplier_invoices i
     set subtotal = x.sub, vat_amount = x.vat, total = x.sub + x.vat
    from (select coalesce(sum(line_total), 0) as sub, coalesce(sum(vat_amount), 0) as vat
            from public.supplier_invoice_items where invoice_id = v_id) x
   where i.id = v_id;
  return v_id;
end;
$$;

-- المطابقة الثلاثية سطراً بسطر
create or replace function public.match_invoice(p_id uuid)
returns table (line_id uuid, receipt_item_id uuid, variant_id uuid, sku text, product_name text,
               qty_ordered integer, qty_received integer, qty_invoiced_before integer, qty_this integer,
               po_unit_cost numeric, invoice_unit_cost numeric, diff_pct numeric, result text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare
  v_tol numeric := (select purchase_match_tolerance_pct from public.store_settings where id = 1);
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  return query
  with lines as (
    select l.id, l.receipt_item_id, l.variant_id, l.qty, l.unit_cost, gi.unit_cost as po_cost, gi.qty as gr_qty,
           gi.qty_invoiced, pi.qty as ordered,
           -- نفس سطر الاستلام في أكثر من سطر من نفس الفاتورة
           sum(l.qty) over (partition by l.receipt_item_id) as qty_in_invoice
      from public.supplier_invoice_items l
      join public.goods_receipt_items gi on gi.id = l.receipt_item_id
      join public.purchase_items pi on pi.id = gi.purchase_item_id
     where l.invoice_id = p_id
  )
  select l.id, l.receipt_item_id, l.variant_id, v.sku, p.name, l.ordered, l.gr_qty, l.qty_invoiced, l.qty,
         l.po_cost, l.unit_cost,
         case when l.po_cost > 0 then round(abs(l.unit_cost - l.po_cost) / l.po_cost * 100, 2)
              when l.unit_cost > 0 then 100 else 0 end,
         case when l.qty_in_invoice > l.gr_qty - l.qty_invoiced then 'qty_over_received'
              when l.unit_cost = l.po_cost then 'matched'
              when l.po_cost > 0 and abs(l.unit_cost - l.po_cost) / l.po_cost * 100 <= v_tol then 'within_tolerance'
              else 'price_over_tolerance' end
    from lines l
    join public.product_variants v on v.id = l.variant_id
    join public.products p on p.id = v.product_id
   order by p.name, v.sku;
end;
$$;

-- ترحيل الفاتورة. p_payment للسداد النقدي/الجزئي: {method, reference, amount(للجزئي)}
create or replace function public.post_supplier_invoice(
  p_id uuid, p_override_reason text default null, p_payment jsonb default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  i public.supplier_invoices;
  r record;
  v_status text := 'not_required';
  v_pay numeric;
  v_method public.ap_payment_method;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  -- ضغطتان على «ترحيل»: الثانية تنتظر ثم تجد الفاتورة مرحّلة وتعود بلا أثر
  perform pg_advisory_xact_lock(hashtextextended('sin-post:' || p_id::text, 0));
  select * into i from public.supplier_invoices where id = p_id;
  if i.id is null then
    raise exception 'الفاتورة غير موجودة';
  end if;
  perform public._lock_supplier(i.supplier_id);
  select * into i from public.supplier_invoices where id = p_id for update;
  if i.status <> 'draft' then
    if i.status = 'void' then
      raise exception 'الفاتورة ملغاة';
    end if;
    return p_id;
  end if;
  if i.total <= 0 or not exists (select 1 from public.supplier_invoice_items where invoice_id = p_id) then
    raise exception 'الفاتورة بدون مبلغ';
  end if;
  if i.supplier_invoice_no is null and i.kind = 'purchase' then
    raise exception 'أدخل رقم فاتورة المورد';
  end if;

  -- المطابقة
  if exists (select 1 from public.supplier_invoice_items where invoice_id = p_id and receipt_item_id is not null) then
    v_status := 'matched';
    for r in select * from public.match_invoice(p_id) loop
      if r.result = 'qty_over_received' then
        raise exception 'الكمية المفوترة من % أكبر من المستلم غير المفوتر', r.sku;
      elsif r.result = 'price_over_tolerance' then
        if coalesce(trim(p_override_reason), '') = '' then
          raise exception 'فرق السعر في % (% مقابل % في أمر الشراء، %%%) خارج نسبة السماح — يتطلب تجاوزاً بسبب',
            r.sku, r.invoice_unit_cost, r.po_unit_cost, r.diff_pct;
        end if;
        v_status := 'override';
      elsif r.result = 'within_tolerance' and v_status = 'matched' then
        v_status := 'within_tolerance';
      end if;
    end loop;
    if v_status = 'override' and (select inventory_segregation from public.store_settings where id = 1)
       and i.created_by = auth.uid() then
      raise exception 'فصل المهام مفعّل: من أنشأ الفاتورة لا يعتمد تجاوز مطابقتها';
    end if;
  end if;

  perform set_config('app.po_rpc', 'on', true);
  for r in select l.*, gi.purchase_item_id, gi.unit_cost as grn_cost
             from public.supplier_invoice_items l join public.goods_receipt_items gi on gi.id = l.receipt_item_id
            where l.invoice_id = p_id order by l.id loop
    update public.goods_receipt_items set qty_invoiced = qty_invoiced + r.qty where id = r.receipt_item_id;
    update public.purchase_items set qty_invoiced = qty_invoiced + r.qty where id = r.purchase_item_id;
    perform public._apply_cost_adjustment(r.variant_id, r.qty, round(r.qty * (r.unit_cost - r.grn_cost), 2), 'invoice_price', p_id);
  end loop;
  perform set_config('app.po_rpc', '', true);

  update public.supplier_invoices
     set status = 'posted', posted_by = auth.uid(), posted_at = now(), match_status = v_status,
         match_override_by = case when v_status = 'override' then auth.uid() end,
         match_override_reason = case when v_status = 'override' then trim(p_override_reason) end
   where id = p_id;
  perform public._ap_post(i.supplier_id, 'invoice', p_id, coalesce(i.supplier_invoice_no, i.doc_no), 0, i.total,
                          i.doc_no, i.invoice_date);

  -- السداد عند الترحيل
  if i.payment_terms in ('cash', 'partial') then
    v_pay := case when i.payment_terms = 'cash' then i.total else (p_payment ->> 'amount')::numeric end;
    if v_pay is null or v_pay <= 0 or v_pay > i.total or (i.payment_terms = 'partial' and v_pay >= i.total) then
      raise exception 'أدخل مبلغ الدفعة الجزئية (أقل من إجمالي الفاتورة)';
    end if;
    v_method := coalesce(p_payment ->> 'method', 'cash')::public.ap_payment_method;
    perform public.post_supplier_payment(i.supplier_id, v_pay, v_method, p_payment ->> 'reference', i.invoice_date,
                                         jsonb_build_array(jsonb_build_object('invoice_id', p_id, 'amount', v_pay)),
                                         'سداد ' || coalesce(i.supplier_invoice_no, i.doc_no),
                                         md5('pay:' || p_id::text)::uuid);
  end if;
  return p_id;
end;
$$;

-- إلغاء فاتورة مرحّلة: بشرط عدم وجود سداد عليها. يعكس الكميات المفوترة وتعديل التكلفة والقيد
create or replace function public.void_supplier_invoice(p_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  i public.supplier_invoices;
  r record;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'السبب مطلوب';
  end if;
  select * into i from public.supplier_invoices where id = p_id;
  if i.id is null then
    raise exception 'الفاتورة غير موجودة';
  end if;
  perform public._lock_supplier(i.supplier_id);
  select * into i from public.supplier_invoices where id = p_id for update;
  if i.status = 'draft' then
    update public.supplier_invoices set status = 'void', void_reason = trim(p_reason), voided_by = auth.uid(), voided_at = now()
     where id = p_id;
    return;
  end if;
  if i.status = 'void' then
    raise exception 'الفاتورة ملغاة مسبقاً';
  end if;
  if i.kind = 'opening' then
    raise exception 'لا يُلغى الرصيد الافتتاحي';
  end if;
  if i.settled_amount > 0 then
    raise exception 'على الفاتورة سداد — ألغِ الدفعات أولاً';
  end if;
  if exists (select 1 from public.supplier_invoice_items l join public.goods_receipt_items gi on gi.id = l.receipt_item_id
              where l.invoice_id = p_id and gi.qty_returned > gi.qty_invoiced - l.qty) then
    raise exception 'أُرجع جزء من هذه البضاعة للمورد — عالج المرتجع أولاً';
  end if;

  perform set_config('app.po_rpc', 'on', true);
  for r in select l.*, gi.purchase_item_id, gi.unit_cost as grn_cost
             from public.supplier_invoice_items l join public.goods_receipt_items gi on gi.id = l.receipt_item_id
            where l.invoice_id = p_id loop
    update public.goods_receipt_items set qty_invoiced = qty_invoiced - r.qty where id = r.receipt_item_id;
    update public.purchase_items set qty_invoiced = qty_invoiced - r.qty where id = r.purchase_item_id;
    perform public._apply_cost_adjustment(r.variant_id, r.qty, -round(r.qty * (r.unit_cost - r.grn_cost), 2), 'invoice_void', p_id);
  end loop;
  perform set_config('app.po_rpc', '', true);

  update public.supplier_invoices set status = 'void', void_reason = trim(p_reason), voided_by = auth.uid(), voided_at = now()
   where id = p_id;
  perform public._ap_post(i.supplier_id, 'void_invoice', p_id, coalesce(i.supplier_invoice_no, i.doc_no), i.total, 0,
                          'إلغاء: ' || trim(p_reason));
end;
$$;

-- ---------------------------------------------------------------------
-- شراء مباشر بدون أمر شراء مسبق: أمر شراء + استلام كامل + فاتورة مرحّلة (+ سداد) في عملية واحدة
-- ---------------------------------------------------------------------
create or replace function public.create_direct_purchase(
  p_supplier uuid, p_location uuid, p_items jsonb, p_supplier_invoice_no text, p_invoice_date date,
  p_payment_terms public.ap_payment_terms, p_payment jsonb default null, p_notes text default null, p_client_ref uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_po uuid;
  v_grn uuid;
  v_inv uuid;
  e jsonb;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtextextended('direct:' || p_client_ref::text, 0));
    select id into v_inv from public.supplier_invoices where client_ref = p_client_ref;
    if v_inv is not null then
      return v_inv;
    end if;
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'لا توجد أصناف';
  end if;
  perform public._lock_supplier(p_supplier);
  insert into public.purchase_orders (po_no, supplier_id, status, supplier_invoice_no, notes, location_id, approved_by, approved_at)
  values (public.next_po_no(), p_supplier, 'ordered', nullif(trim(p_supplier_invoice_no), ''),
          coalesce(nullif(trim(p_notes), ''), 'شراء مباشر'), p_location, auth.uid(), now())
  returning id into v_po;
  for e in select * from jsonb_array_elements(p_items) loop
    if coalesce((e ->> 'qty')::integer, 0) <= 0 or coalesce((e ->> 'unit_cost')::numeric, -1) < 0 then
      raise exception 'كمية أو سعر غير صحيح';
    end if;
    insert into public.purchase_items (purchase_id, variant_id, qty, unit_cost)
    values (v_po, (e ->> 'variant_id')::uuid, (e ->> 'qty')::integer, (e ->> 'unit_cost')::numeric);
  end loop;
  v_grn := public.receive_goods(v_po, null, 'شراء مباشر', null);
  v_inv := public.save_supplier_invoice(
    null, p_supplier, v_po, p_supplier_invoice_no, p_invoice_date, null, p_payment_terms,
    (select jsonb_agg(jsonb_build_object('receipt_item_id', gi.id, 'qty', gi.qty, 'unit_cost', gi.unit_cost))
       from public.goods_receipt_items gi where gi.receipt_id = v_grn),
    p_notes, p_client_ref);
  perform public.post_supplier_invoice(v_inv, null, p_payment);
  return v_inv;
end;
$$;

-- ---------------------------------------------------------------------
-- المرفقات: تسجيل ملف مرفوع إلى purchase-docs/<owner_type>/<owner_id>/…
-- ---------------------------------------------------------------------
create or replace function public.add_purchase_attachment(
  p_owner_type text, p_owner_id uuid, p_path text, p_name text, p_mime text, p_size integer
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if p_path is null or split_part(p_path, '/', 1) <> p_owner_type or split_part(p_path, '/', 2) <> p_owner_id::text then
    raise exception 'مسار الملف لا يطابق المستند';
  end if;
  if p_mime not in ('application/pdf', 'image/jpeg', 'image/png', 'image/webp') then
    raise exception 'نوع الملف غير مسموح (PDF أو صورة فقط)';
  end if;
  insert into public.purchase_attachments (owner_type, owner_id, file_path, file_name, mime_type, size_bytes)
  values (p_owner_type, p_owner_id, p_path, left(coalesce(nullif(trim(p_name), ''), 'file'), 200), p_mime, p_size)
  on conflict (file_path) do update set file_name = excluded.file_name
  returning id into v_id;
  return v_id;
end;
$$;

-- فرق التكلفة (نصيب ما بيع قبل وصول الفاتورة/التكاليف) لفترة — يظهر في لوحة المشتريات والتقارير
create or replace function public.cost_variance_summary(p_from date, p_to date)
returns table (source_type text, adjustments integer, total_delta numeric, stock_delta numeric, variance_delta numeric)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  return query
    select c.source_type, count(*)::integer, sum(c.total_delta), sum(c.stock_delta), sum(c.variance_delta)
      from public.cost_adjustments c
     where (c.posted_at at time zone 'Asia/Riyadh')::date between p_from and p_to
     group by 1 order by 1;
end;
$$;

-- الكمية المطلوبة من المورد ولم تصل: المتبقي من المسودة والمرسل والمستلم جزئياً
create or replace function public._open_po_qty()
returns table (loc uuid, variant_id uuid, qty integer)
language sql stable security definer set search_path = public as $$
  select coalesce(po.location_id, public._default_location()), pi.variant_id, sum(pi.qty - pi.qty_received)::integer
    from public.purchase_items pi join public.purchase_orders po on po.id = pi.purchase_id
   where po.status::text in ('draft', 'ordered', 'partially_received') and pi.qty > pi.qty_received
   group by 1, 2
$$;

-- ---------------------------------------------------------------------
-- الصلاحيات
-- ---------------------------------------------------------------------
alter table public.goods_receipts enable row level security;
alter table public.goods_receipt_items enable row level security;
alter table public.supplier_invoice_items enable row level security;
alter table public.cost_adjustments enable row level security;
alter table public.purchase_attachments enable row level security;

revoke all on public.goods_receipts, public.goods_receipt_items, public.supplier_invoice_items,
  public.cost_adjustments, public.purchase_attachments from anon, authenticated;
revoke usage on sequence public.goods_receipt_seq from anon;
grant select on public.goods_receipts, public.goods_receipt_items, public.supplier_invoice_items,
  public.cost_adjustments, public.purchase_attachments to authenticated;

create policy goods_receipts_select on public.goods_receipts for select to authenticated using (public.is_manager());
create policy goods_receipt_items_select on public.goods_receipt_items for select to authenticated using (public.is_manager());
create policy supplier_invoice_items_select on public.supplier_invoice_items for select to authenticated using (public.is_manager());
create policy cost_adjustments_select on public.cost_adjustments for select to authenticated using (public.is_manager());
create policy purchase_attachments_select on public.purchase_attachments for select to authenticated using (public.is_manager());

create trigger goods_receipts_audit after insert or update or delete on public.goods_receipts
  for each row execute function public.audit_trigger();
create trigger supplier_invoice_items_audit after insert or update or delete on public.supplier_invoice_items
  for each row execute function public.audit_trigger();
create trigger purchase_attachments_audit after insert or update or delete on public.purchase_attachments
  for each row execute function public.audit_trigger();

revoke all on function
  public.purchase_order_guard(), public.purchase_item_guard(),
  public._apply_cost_adjustment(uuid, integer, numeric, text, uuid), public._vat_rate_for(uuid)
from public, anon, authenticated;

revoke execute on function
  public.approve_purchase_order(uuid), public.close_purchase_order(uuid, text),
  public.receive_goods(uuid, jsonb, text, uuid),
  public.save_supplier_invoice(uuid, uuid, uuid, text, date, date, public.ap_payment_terms, jsonb, text, uuid),
  public.match_invoice(uuid), public.post_supplier_invoice(uuid, text, jsonb), public.void_supplier_invoice(uuid, text),
  public.create_direct_purchase(uuid, uuid, jsonb, text, date, public.ap_payment_terms, jsonb, text, uuid),
  public.add_purchase_attachment(text, uuid, text, text, text, integer), public.cost_variance_summary(date, date)
from public, anon;
grant execute on function
  public.approve_purchase_order(uuid), public.close_purchase_order(uuid, text),
  public.receive_goods(uuid, jsonb, text, uuid),
  public.save_supplier_invoice(uuid, uuid, uuid, text, date, date, public.ap_payment_terms, jsonb, text, uuid),
  public.match_invoice(uuid), public.post_supplier_invoice(uuid, text, jsonb), public.void_supplier_invoice(uuid, text),
  public.create_direct_purchase(uuid, uuid, jsonb, text, date, public.ap_payment_terms, jsonb, text, uuid),
  public.add_purchase_attachment(text, uuid, text, text, text, integer), public.cost_variance_summary(date, date)
to authenticated;
commit;

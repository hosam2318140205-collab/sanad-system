-- =====================================================================
-- دوال العمليات (RPC) — كل عملية مالية أو مخزنية ذرّية وتتحقق من الصلاحيات
-- =====================================================================

-- ---------------------------------------------------------------------
-- إتمام عملية بيع
-- p_items    : [{ "variant_id": uuid, "qty": int, "discount": numeric }]
--              discount = خصم السطر بنفس أساس السعر (شامل/غير شامل الضريبة حسب الإعداد)
-- p_payments : [{ "method": "cash|card|transfer|exchange_credit", "amount": numeric,
--                 "reference": text, "return_id": uuid }]
-- الأسعار تُقرأ من قاعدة البيانات وليس من المتصفح
-- ---------------------------------------------------------------------
create or replace function public.complete_sale(
  p_items jsonb,
  p_payments jsonb,
  p_customer_id uuid default null,
  p_invoice_discount numeric default 0,
  p_notes text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role public.user_role := public.current_user_role();
  s public.store_settings;
  v_sale_id uuid;
  v_item jsonb;
  v_pay jsonb;
  v_lines jsonb := '[]'::jsonb;
  v_line jsonb;
  v_variant record;
  v_qty integer;
  v_price numeric;
  v_gross numeric;
  v_disc numeric;
  v_sum_gross numeric := 0;
  v_sum_line_disc numeric := 0;
  v_sum_base numeric;
  v_inv_disc numeric;
  v_alloc numeric;
  v_alloc_done numeric := 0;
  v_net numeric;
  v_line_total numeric;
  v_line_vat numeric;
  v_total numeric := 0;
  v_vat numeric := 0;
  v_paid numeric := 0;
  v_cash numeric := 0;
  v_noncash numeric := 0;
  v_change numeric;
  v_method public.payment_method;
  v_amount numeric;
  v_return public.returns;
  v_count integer;
  v_idx integer := 0;
begin
  if v_role is null then
    raise exception 'غير مصرح';
  end if;
  select * into s from public.store_settings where id = 1;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'السلة فارغة';
  end if;
  v_count := jsonb_array_length(p_items);

  -- المرور الأول: التحقق وحساب الإجمالي قبل خصم الفاتورة
  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty := (v_item ->> 'qty')::integer;
    if v_qty is null or v_qty <= 0 then
      raise exception 'كمية غير صحيحة';
    end if;

    select v.id, v.sku, v.size, v.color, coalesce(v.price, p.base_price) as price,
           p.name, v.is_active and p.is_active as active,
           coalesce(c.cost_price, 0) as cost
      into v_variant
      from public.product_variants v
      join public.products p on p.id = v.product_id
      left join public.variant_costs c on c.variant_id = v.id
     where v.id = (v_item ->> 'variant_id')::uuid;

    if v_variant.id is null then
      raise exception 'صنف غير موجود';
    end if;
    if not v_variant.active then
      raise exception 'الصنف % موقوف', v_variant.sku;
    end if;

    v_gross := round(v_variant.price * v_qty, 2);
    v_disc := least(greatest(coalesce((v_item ->> 'discount')::numeric, 0), 0), v_gross);
    v_sum_gross := v_sum_gross + v_gross;
    v_sum_line_disc := v_sum_line_disc + v_disc;

    v_lines := v_lines || jsonb_build_object(
      'variant_id', v_variant.id,
      'sku', v_variant.sku,
      'product_name', v_variant.name,
      'variant_label', nullif(concat_ws(' / ', v_variant.size, v_variant.color), ''),
      'qty', v_qty,
      'unit_price', v_variant.price,
      'gross', v_gross,
      'disc', round(v_disc, 2),
      'cost', v_variant.cost
    );
  end loop;

  v_sum_base := v_sum_gross - v_sum_line_disc;
  v_inv_disc := round(least(greatest(coalesce(p_invoice_discount, 0), 0), v_sum_base), 2);

  -- حد الخصم للكاشير
  if v_role = 'cashier' and v_sum_gross > 0
     and (v_sum_line_disc + v_inv_disc) / v_sum_gross * 100 > s.max_cashier_discount_pct + 0.001 then
    raise exception 'الخصم يتجاوز الحد المسموح للكاشير (% %%)', s.max_cashier_discount_pct;
  end if;

  -- المرور الثاني: توزيع خصم الفاتورة وحساب الضريبة لكل سطر
  for v_idx in 0 .. v_count - 1 loop
    v_line := v_lines -> v_idx;
    v_net := (v_line ->> 'gross')::numeric - (v_line ->> 'disc')::numeric;
    if v_idx = v_count - 1 then
      v_alloc := v_inv_disc - v_alloc_done;
    elsif v_sum_base > 0 then
      v_alloc := round(v_inv_disc * v_net / v_sum_base, 2);
    else
      v_alloc := 0;
    end if;
    v_alloc_done := v_alloc_done + v_alloc;
    v_net := v_net - v_alloc;

    if s.prices_include_vat then
      v_line_total := round(v_net, 2);
      v_line_vat := round(v_net * s.vat_rate / (100 + s.vat_rate), 2);
    else
      v_line_vat := round(v_net * s.vat_rate / 100, 2);
      v_line_total := round(v_net, 2) + v_line_vat;
    end if;

    v_total := v_total + v_line_total;
    v_vat := v_vat + v_line_vat;
    v_lines := jsonb_set(v_lines, array[v_idx::text], v_line || jsonb_build_object(
      'line_discount', (v_line ->> 'disc')::numeric + v_alloc,
      'line_total', v_line_total,
      'vat', v_line_vat
    ));
  end loop;

  -- الدفعات
  if p_payments is null or jsonb_typeof(p_payments) <> 'array' or jsonb_array_length(p_payments) = 0 then
    raise exception 'لم يتم تحديد طريقة الدفع';
  end if;

  for v_pay in select * from jsonb_array_elements(p_payments) loop
    v_method := (v_pay ->> 'method')::public.payment_method;
    v_amount := round((v_pay ->> 'amount')::numeric, 2);
    if v_amount is null or v_amount <= 0 then
      raise exception 'مبلغ دفع غير صحيح';
    end if;
    if v_method = 'exchange_credit' then
      select * into v_return from public.returns
       where id = (v_pay ->> 'return_id')::uuid for update;
      if v_return.id is null or v_return.refund_method <> 'exchange' then
        raise exception 'رصيد الاستبدال غير صالح';
      end if;
      if v_return.credit_used_by_sale is not null then
        raise exception 'رصيد الاستبدال % مستخدم مسبقاً', v_return.return_no;
      end if;
      if v_amount <> v_return.total then
        raise exception 'يجب استخدام رصيد الاستبدال كاملاً (% ر.س)', v_return.total;
      end if;
    end if;
    if v_method = 'cash' then
      v_cash := v_cash + v_amount;
    else
      v_noncash := v_noncash + v_amount;
    end if;
    v_paid := v_paid + v_amount;
  end loop;

  if v_noncash > v_total + 0.001 then
    raise exception 'مبالغ الشبكة/التحويل/الاستبدال (% ) أكبر من إجمالي الفاتورة (% )', v_noncash, v_total;
  end if;
  if v_paid + 0.001 < v_total then
    raise exception 'المبلغ المدفوع (% ) أقل من الإجمالي (% )', v_paid, v_total;
  end if;
  v_change := round(v_paid - v_total, 2);

  if p_customer_id is not null and not exists (select 1 from public.customers where id = p_customer_id) then
    raise exception 'العميل غير موجود';
  end if;

  insert into public.sales (
    invoice_no, customer_id, cashier_id, subtotal, discount_total, invoice_discount,
    vat_rate, vat_amount, total, paid_amount, change_amount, notes
  ) values (
    'INV-' || to_char(now() at time zone 'Asia/Riyadh', 'YY') || lpad(nextval('public.invoice_seq')::text, 6, '0'),
    p_customer_id, auth.uid(), v_total - v_vat, v_sum_line_disc + v_inv_disc, v_inv_disc,
    s.vat_rate, v_vat, v_total, v_paid, v_change, nullif(trim(p_notes), '')
  ) returning id into v_sale_id;

  insert into public.sale_items (
    sale_id, variant_id, product_name, variant_label, sku, qty, unit_price,
    line_discount, line_total, vat_amount, unit_cost
  )
  select v_sale_id, (l ->> 'variant_id')::uuid, l ->> 'product_name', l ->> 'variant_label',
         l ->> 'sku', (l ->> 'qty')::integer, (l ->> 'unit_price')::numeric,
         (l ->> 'line_discount')::numeric, (l ->> 'line_total')::numeric,
         (l ->> 'vat')::numeric, (l ->> 'cost')::numeric
    from jsonb_array_elements(v_lines) l;

  for v_line in select * from jsonb_array_elements(v_lines) loop
    perform public._move_stock(
      (v_line ->> 'variant_id')::uuid, -((v_line ->> 'qty')::integer), 'sale', v_sale_id,
      null, not s.allow_negative_stock);
  end loop;

  for v_pay in select * from jsonb_array_elements(p_payments) loop
    v_method := (v_pay ->> 'method')::public.payment_method;
    insert into public.sale_payments (sale_id, method, amount, reference, exchange_return_id)
    values (
      v_sale_id, v_method, round((v_pay ->> 'amount')::numeric, 2),
      nullif(v_pay ->> 'reference', ''),
      case when v_method = 'exchange_credit' then (v_pay ->> 'return_id')::uuid end
    );
    if v_method = 'exchange_credit' then
      update public.returns set credit_used_by_sale = v_sale_id
       where id = (v_pay ->> 'return_id')::uuid;
    end if;
  end loop;

  return v_sale_id;
end;
$$;

-- ---------------------------------------------------------------------
-- جلب فاتورة للإرجاع (بدون بيانات التكلفة)
-- ---------------------------------------------------------------------
create or replace function public.get_sale_for_return(p_invoice_no text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_role public.user_role := public.current_user_role();
  s public.store_settings;
  v_sale public.sales;
begin
  select * into s from public.store_settings where id = 1;
  if v_role is null or (v_role = 'cashier' and not s.allow_cashier_returns) then
    raise exception 'غير مصرح بعمليات الإرجاع';
  end if;

  select * into v_sale from public.sales where upper(invoice_no) = upper(trim(p_invoice_no));
  if v_sale.id is null then
    raise exception 'الفاتورة غير موجودة';
  end if;

  return jsonb_build_object(
    'id', v_sale.id,
    'invoice_no', v_sale.invoice_no,
    'created_at', v_sale.created_at,
    'total', v_sale.total,
    'returned_amount', v_sale.returned_amount,
    'status', v_sale.status,
    'customer_name', (select name from public.customers where id = v_sale.customer_id),
    'days_since', (now() at time zone 'Asia/Riyadh')::date - (v_sale.created_at at time zone 'Asia/Riyadh')::date,
    'return_days', s.return_days,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', i.id, 'variant_id', i.variant_id, 'product_name', i.product_name,
        'variant_label', i.variant_label, 'sku', i.sku, 'qty', i.qty,
        'returned_qty', i.returned_qty, 'unit_price', i.unit_price,
        'line_total', i.line_total, 'vat_amount', i.vat_amount
      ) order by i.product_name)
      from public.sale_items i where i.sale_id = v_sale.id), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- مرتجع / استبدال
-- p_items : [{ "sale_item_id": uuid, "qty": int, "restock": bool }]
-- p_refund_method = 'exchange' ينشئ رصيد استبدال يُستخدم في فاتورة جديدة
-- ---------------------------------------------------------------------
create or replace function public.process_return(
  p_sale_id uuid,
  p_items jsonb,
  p_refund_method public.refund_method,
  p_reason text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role public.user_role := public.current_user_role();
  s public.store_settings;
  v_sale public.sales;
  v_item jsonb;
  v_si public.sale_items;
  v_qty integer;
  v_amount numeric;
  v_vat numeric;
  v_prev_amount numeric;
  v_prev_vat numeric;
  v_total numeric := 0;
  v_total_vat numeric := 0;
  v_return_id uuid;
  v_restock boolean;
  v_remaining integer;
begin
  select * into s from public.store_settings where id = 1;
  if v_role is null or (v_role = 'cashier' and not s.allow_cashier_returns) then
    raise exception 'غير مصرح بعمليات الإرجاع';
  end if;

  select * into v_sale from public.sales where id = p_sale_id for update;
  if v_sale.id is null then
    raise exception 'الفاتورة غير موجودة';
  end if;
  if v_sale.status = 'returned' then
    raise exception 'الفاتورة مرتجعة بالكامل';
  end if;
  if v_role = 'cashier'
     and (now() at time zone 'Asia/Riyadh')::date - (v_sale.created_at at time zone 'Asia/Riyadh')::date > s.return_days then
    raise exception 'انتهت مدة الإرجاع (% أيام) — يحتاج موافقة المدير', s.return_days;
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'لم يتم اختيار أصناف للإرجاع';
  end if;

  insert into public.returns (return_no, sale_id, cashier_id, refund_method, total, vat_amount, reason)
  values (
    'RET-' || to_char(now() at time zone 'Asia/Riyadh', 'YY') || lpad(nextval('public.return_seq')::text, 6, '0'),
    p_sale_id, auth.uid(), p_refund_method, 0, 0, nullif(trim(p_reason), '')
  ) returning id into v_return_id;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty := (v_item ->> 'qty')::integer;
    if v_qty is null or v_qty <= 0 then
      continue;
    end if;
    v_restock := coalesce((v_item ->> 'restock')::boolean, true);

    select * into v_si from public.sale_items
     where id = (v_item ->> 'sale_item_id')::uuid and sale_id = p_sale_id for update;
    if v_si.id is null then
      raise exception 'صنف غير موجود في الفاتورة';
    end if;
    v_remaining := v_si.qty - v_si.returned_qty;
    if v_qty > v_remaining then
      raise exception 'الكمية المرتجعة للصنف % أكبر من المتبقي (%)', v_si.sku, v_remaining;
    end if;

    if v_qty = v_remaining then
      -- آخر كمية: نرجع المتبقي بالضبط لتجنب فروقات التقريب
      select coalesce(sum(amount), 0), coalesce(sum(vat_amount), 0)
        into v_prev_amount, v_prev_vat
        from public.return_items where sale_item_id = v_si.id;
      v_amount := v_si.line_total - v_prev_amount;
      v_vat := v_si.vat_amount - v_prev_vat;
    else
      v_amount := round(v_si.line_total * v_qty / v_si.qty, 2);
      v_vat := round(v_si.vat_amount * v_qty / v_si.qty, 2);
    end if;

    insert into public.return_items (return_id, sale_item_id, variant_id, qty, amount, vat_amount, restocked)
    values (v_return_id, v_si.id, v_si.variant_id, v_qty, v_amount, v_vat, v_restock);

    update public.sale_items set returned_qty = returned_qty + v_qty where id = v_si.id;

    if v_restock then
      perform public._move_stock(v_si.variant_id, v_qty, 'return', v_return_id, v_sale.invoice_no, false);
    end if;

    v_total := v_total + v_amount;
    v_total_vat := v_total_vat + v_vat;
  end loop;

  if v_total <= 0 then
    raise exception 'لم يتم اختيار أصناف للإرجاع';
  end if;

  update public.returns set total = v_total, vat_amount = v_total_vat where id = v_return_id;

  update public.sales
     set returned_amount = returned_amount + v_total,
         status = case
           when not exists (select 1 from public.sale_items where sale_id = p_sale_id and returned_qty < qty)
             then 'returned'::public.sale_status
           else 'partially_returned'::public.sale_status end
   where id = p_sale_id;

  return v_return_id;
end;
$$;

-- ---------------------------------------------------------------------
-- تسوية المخزون (زيادة/نقص) — مدير أو مالك
-- ---------------------------------------------------------------------
create or replace function public.adjust_stock(p_variant_id uuid, p_qty_change integer, p_note text)
returns integer
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if p_qty_change = 0 then
    raise exception 'الكمية يجب ألا تكون صفراً';
  end if;
  if coalesce(trim(p_note), '') = '' then
    raise exception 'سبب التسوية مطلوب';
  end if;
  return public._move_stock(p_variant_id, p_qty_change, 'adjustment', null, p_note, false);
end;
$$;

-- ---------------------------------------------------------------------
-- استلام أمر شراء: زيادة المخزون وتحديث متوسط التكلفة المرجح
-- ---------------------------------------------------------------------
create or replace function public.receive_purchase(p_purchase_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_po public.purchase_orders;
  v_item record;
  v_old_qty integer;
  v_old_cost numeric;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;

  select * into v_po from public.purchase_orders where id = p_purchase_id for update;
  if v_po.id is null then
    raise exception 'أمر الشراء غير موجود';
  end if;
  if v_po.status not in ('draft', 'ordered') then
    raise exception 'لا يمكن استلام أمر شراء بحالة %', v_po.status;
  end if;
  if not exists (select 1 from public.purchase_items where purchase_id = p_purchase_id) then
    raise exception 'أمر الشراء لا يحتوي أصنافاً';
  end if;

  for v_item in select * from public.purchase_items where purchase_id = p_purchase_id loop
    select greatest(v.stock_qty, 0), coalesce(c.cost_price, 0)
      into v_old_qty, v_old_cost
      from public.product_variants v
      left join public.variant_costs c on c.variant_id = v.id
     where v.id = v_item.variant_id for update of v;

    insert into public.variant_costs (variant_id, cost_price)
    values (
      v_item.variant_id,
      case when v_old_qty + v_item.qty > 0
        then round((v_old_qty * v_old_cost + v_item.qty * v_item.unit_cost) / (v_old_qty + v_item.qty), 2)
        else v_item.unit_cost end
    )
    on conflict (variant_id) do update set cost_price = excluded.cost_price;

    perform public._move_stock(v_item.variant_id, v_item.qty, 'purchase', p_purchase_id, v_po.po_no, false);
  end loop;

  update public.purchase_orders
     set status = 'received', received_at = now(), received_by = auth.uid()
   where id = p_purchase_id;
end;
$$;

create or replace function public.next_po_no()
returns text
language sql security definer set search_path = public as $$
  select 'PO-' || to_char(now() at time zone 'Asia/Riyadh', 'YY') || lpad(nextval('public.purchase_seq')::text, 5, '0')
$$;

-- ---------------------------------------------------------------------
-- الجرد
-- ---------------------------------------------------------------------
create or replace function public.start_stock_count(p_category_id uuid default null, p_notes text default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;

  insert into public.stock_counts (count_no, category_id, notes)
  values (
    'CNT-' || to_char(now() at time zone 'Asia/Riyadh', 'YY') || lpad(nextval('public.count_seq')::text, 4, '0'),
    p_category_id, nullif(trim(p_notes), '')
  ) returning id into v_id;

  insert into public.stock_count_items (count_id, variant_id, expected_qty)
  select v_id, v.id, v.stock_qty
    from public.product_variants v
    join public.products p on p.id = v.product_id
   where v.is_active and p.is_active
     and (p_category_id is null or p.category_id = p_category_id);

  return v_id;
end;
$$;

-- الاعتماد: تُضبط كمية كل صنف معدود على الكمية المعدودة
create or replace function public.apply_stock_count(p_count_id uuid)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_count public.stock_counts;
  v_item record;
  v_changed integer := 0;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;

  select * into v_count from public.stock_counts where id = p_count_id for update;
  if v_count.id is null or v_count.status <> 'open' then
    raise exception 'الجرد غير موجود أو مغلق';
  end if;

  for v_item in
    select i.variant_id, i.counted_qty, v.stock_qty
      from public.stock_count_items i
      join public.product_variants v on v.id = i.variant_id
     where i.count_id = p_count_id and i.counted_qty is not null
       and i.counted_qty <> v.stock_qty
       for update of v
  loop
    perform public._move_stock(
      v_item.variant_id, v_item.counted_qty - v_item.stock_qty, 'count', p_count_id, v_count.count_no, false);
    v_changed := v_changed + 1;
  end loop;

  update public.stock_counts
     set status = 'applied', applied_at = now(), applied_by = auth.uid()
   where id = p_count_id;

  return v_changed;
end;
$$;

-- ---------------------------------------------------------------------
-- لوحة التحكم
-- ---------------------------------------------------------------------
create or replace function public.dashboard_stats()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'Asia/Riyadh')::date;
  v_month date := date_trunc('month', v_today)::date;
  v_result jsonb;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;

  with
  s as (
    select id, total, vat_amount, change_amount, (created_at at time zone 'Asia/Riyadh')::date as d
      from public.sales
     where created_at >= (v_today - 30)::timestamp at time zone 'Asia/Riyadh'
        or created_at >= v_month::timestamp at time zone 'Asia/Riyadh'
  ),
  r as (
    select id, total, vat_amount, (created_at at time zone 'Asia/Riyadh')::date as d
      from public.returns
     where created_at >= least(v_today - 30, v_month)::timestamp at time zone 'Asia/Riyadh'
  ),
  si as (
    select s.d, sum(i.line_total - i.vat_amount - i.unit_cost * i.qty) as profit
      from public.sale_items i join s on s.id = i.sale_id group by s.d
  ),
  ri as (
    select r.d, sum(rit.amount - rit.vat_amount - sit.unit_cost * rit.qty) as profit
      from public.return_items rit
      join r on r.id = rit.return_id
      join public.sale_items sit on sit.id = rit.sale_item_id
     group by r.d
  )
  select jsonb_build_object(
    'today', jsonb_build_object(
      'sales', coalesce((select sum(total) from s where d = v_today), 0),
      'count', (select count(*) from s where d = v_today),
      'vat', coalesce((select sum(vat_amount) from s where d = v_today), 0)
             - coalesce((select sum(vat_amount) from r where d = v_today), 0),
      'returns', coalesce((select sum(total) from r where d = v_today), 0),
      'profit', coalesce((select profit from si where d = v_today), 0)
                - coalesce((select profit from ri where d = v_today), 0)
    ),
    'month', jsonb_build_object(
      'sales', coalesce((select sum(total) from s where d >= v_month), 0),
      'count', (select count(*) from s where d >= v_month),
      'returns', coalesce((select sum(total) from r where d >= v_month), 0),
      'profit', coalesce((select sum(profit) from si where d >= v_month), 0)
                - coalesce((select sum(profit) from ri where d >= v_month), 0)
    ),
    'daily', (
      select jsonb_agg(jsonb_build_object(
        'day', g.d,
        'total', coalesce((select sum(total) from s where s.d = g.d), 0)
                 - coalesce((select sum(total) from r where r.d = g.d), 0),
        'count', (select count(*) from s where s.d = g.d)
      ) order by g.d)
      from (select gs::date as d from generate_series(v_today - 13, v_today, interval '1 day') gs) as g
    ),
    'payments_today', coalesce((
      select jsonb_agg(jsonb_build_object('method', method, 'amount', amount))
        from (
          select p.method,
                 sum(p.amount) - case when p.method = 'cash'
                   then coalesce((select sum(change_amount) from s where d = v_today), 0) else 0 end as amount
            from public.sale_payments p join s on s.id = p.sale_id
           where s.d = v_today group by p.method
        ) x), '[]'::jsonb),
    'top_products', coalesce((
      select jsonb_agg(t order by t.qty desc) from (
        select i.product_name as name, sum(i.qty - i.returned_qty) as qty, sum(i.line_total) as total
          from public.sale_items i join s on s.id = i.sale_id
         where s.d > v_today - 30
         group by i.product_name
         order by 2 desc limit 8
      ) t), '[]'::jsonb),
    'low_stock', coalesce((
      select jsonb_agg(t) from (
        select v.id, p.name, v.size, v.color, v.sku, v.stock_qty, v.low_stock_threshold
          from public.product_variants v join public.products p on p.id = v.product_id
         where v.is_active and p.is_active and v.stock_qty <= v.low_stock_threshold
         order by v.stock_qty asc limit 10
      ) t), '[]'::jsonb),
    'low_stock_count', (
      select count(*) from public.product_variants v join public.products p on p.id = v.product_id
       where v.is_active and p.is_active and v.stock_qty <= v.low_stock_threshold),
    'stock_value', (
      select jsonb_build_object(
        'cost', coalesce(sum(greatest(v.stock_qty, 0) * coalesce(c.cost_price, 0)), 0),
        'retail', coalesce(sum(greatest(v.stock_qty, 0) * coalesce(v.price, p.base_price)), 0),
        'units', coalesce(sum(greatest(v.stock_qty, 0)), 0))
        from public.product_variants v
        join public.products p on p.id = v.product_id
        left join public.variant_costs c on c.variant_id = v.id
       where v.is_active and p.is_active),
    'recent', coalesce((
      select jsonb_agg(t) from (
        select sa.id, sa.invoice_no, sa.total, sa.status, sa.created_at, pr.full_name as cashier
          from public.sales sa left join public.profiles pr on pr.id = sa.cashier_id
         order by sa.created_at desc limit 8
      ) t), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------
-- تقرير المبيعات والأرباح لفترة
-- ---------------------------------------------------------------------
create or replace function public.sales_report(p_from date, p_to date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_from timestamptz := p_from::timestamp at time zone 'Asia/Riyadh';
  v_to timestamptz := (p_to + 1)::timestamp at time zone 'Asia/Riyadh';
  v_result jsonb;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;

  with
  s as (select * from public.sales where created_at >= v_from and created_at < v_to),
  i as (select i.*, s.cashier_id from public.sale_items i join s on s.id = i.sale_id),
  r as (select * from public.returns where created_at >= v_from and created_at < v_to),
  ri as (
    select ri.*, si.unit_cost, si.product_name, r.cashier_id
      from public.return_items ri
      join r on r.id = ri.return_id
      join public.sale_items si on si.id = ri.sale_item_id
  ),
  summary as (
    select
      coalesce((select sum(total) from s), 0) as gross_sales,
      (select count(*) from s) as invoices,
      coalesce((select sum(discount_total) from s), 0) as discounts,
      coalesce((select sum(vat_amount) from s), 0) as sales_vat,
      coalesce((select sum(total) from r), 0) as returns_total,
      coalesce((select sum(vat_amount) from r), 0) as returns_vat,
      (select count(*) from r) as returns_count,
      coalesce((select sum(unit_cost * qty) from i), 0) as sales_cost,
      coalesce((select sum(unit_cost * qty) from ri), 0) as returns_cost,
      coalesce((select sum(qty) from i), 0) as items_sold,
      coalesce((select sum(qty) from ri), 0) as items_returned
  )
  select jsonb_build_object(
    'summary', (
      select jsonb_build_object(
        'gross_sales', gross_sales,
        'invoices', invoices,
        'discounts', discounts,
        'returns', returns_total,
        'returns_count', returns_count,
        'net_sales', gross_sales - returns_total,
        'vat', sales_vat - returns_vat,
        'net_excl_vat', (gross_sales - sales_vat) - (returns_total - returns_vat),
        'cost', sales_cost - returns_cost,
        'gross_profit', (gross_sales - sales_vat) - (returns_total - returns_vat) - (sales_cost - returns_cost),
        'margin', case when (gross_sales - sales_vat) - (returns_total - returns_vat) > 0
          then round((((gross_sales - sales_vat) - (returns_total - returns_vat) - (sales_cost - returns_cost))
               / ((gross_sales - sales_vat) - (returns_total - returns_vat))) * 100, 1)
          else 0 end,
        'avg_ticket', case when invoices > 0 then round(gross_sales / invoices, 2) else 0 end,
        'items_sold', items_sold - items_returned
      ) from summary),
    'by_day', coalesce((
      select jsonb_agg(t order by t.day) from (
        select d as day,
               coalesce(sum(sales), 0) as sales,
               coalesce(sum(returns), 0) as returns,
               coalesce(sum(invoices), 0) as invoices,
               coalesce(sum(profit), 0) as profit
          from (
            select (s.created_at at time zone 'Asia/Riyadh')::date as d, s.total as sales, 0 as returns, 1 as invoices,
                   (s.subtotal - (select coalesce(sum(unit_cost * qty), 0) from i where i.sale_id = s.id)) as profit
              from s
            union all
            select (r.created_at at time zone 'Asia/Riyadh')::date, 0, r.total, 0,
                   -((r.total - r.vat_amount) - (select coalesce(sum(unit_cost * qty), 0) from ri where ri.return_id = r.id))
              from r
          ) x group by d
      ) t), '[]'::jsonb),
    'by_payment', coalesce((
      select jsonb_agg(jsonb_build_object('method', method, 'amount', amount, 'count', cnt))
        from (
          select p.method,
                 sum(p.amount) - case when p.method = 'cash' then coalesce((select sum(change_amount) from s), 0) else 0 end as amount,
                 count(distinct p.sale_id) as cnt
            from public.sale_payments p join s on s.id = p.sale_id
           group by p.method
        ) x), '[]'::jsonb),
    'refunds_by_method', coalesce((
      select jsonb_agg(jsonb_build_object('method', refund_method, 'amount', amount, 'count', cnt))
        from (select refund_method, sum(total) as amount, count(*) as cnt from r group by refund_method) x
      ), '[]'::jsonb),
    'by_cashier', coalesce((
      select jsonb_agg(t order by t.sales desc) from (
        select pr.full_name as name, count(*) as invoices, sum(s.total) as sales
          from s left join public.profiles pr on pr.id = s.cashier_id
         group by pr.full_name
      ) t), '[]'::jsonb),
    'top_products', coalesce((
      select jsonb_agg(t order by t.revenue desc) from (
        select i.product_name as name,
               sum(i.qty) as qty,
               sum(i.line_total) as revenue,
               sum(i.line_total - i.vat_amount - i.unit_cost * i.qty) as profit
          from i group by i.product_name
         order by 3 desc limit 15
      ) t), '[]'::jsonb),
    'by_category', coalesce((
      select jsonb_agg(t order by t.revenue desc) from (
        select coalesce(c.name, 'بدون تصنيف') as name, sum(i.qty) as qty, sum(i.line_total) as revenue,
               sum(i.line_total - i.vat_amount - i.unit_cost * i.qty) as profit
          from i
          join public.product_variants v on v.id = i.variant_id
          join public.products p on p.id = v.product_id
          left join public.categories c on c.id = p.category_id
         group by c.name
      ) t), '[]'::jsonb),
    'by_size', coalesce((
      select jsonb_agg(t order by t.qty desc) from (
        select coalesce(v.size, '-') as name, sum(i.qty) as qty, sum(i.line_total) as revenue
          from i join public.product_variants v on v.id = i.variant_id
         group by v.size
      ) t), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------
-- ملخص العميل
-- ---------------------------------------------------------------------
create or replace function public.customer_stats(p_customer_id uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select case when public.is_staff() then jsonb_build_object(
    'invoices', count(*),
    'total_spent', coalesce(sum(total - returned_amount), 0),
    'last_visit', max(created_at)
  ) end
  from public.sales where customer_id = p_customer_id
$$;

-- صلاحيات التنفيذ
revoke execute on all functions in schema public from anon, public;
grant execute on function
  public.current_user_role(), public.has_role(public.user_role[]), public.is_staff(), public.is_manager(),
  public.complete_sale(jsonb, jsonb, uuid, numeric, text),
  public.get_sale_for_return(text),
  public.process_return(uuid, jsonb, public.refund_method, text),
  public.adjust_stock(uuid, integer, text),
  public.receive_purchase(uuid),
  public.next_po_no(),
  public.start_stock_count(uuid, text),
  public.apply_stock_count(uuid),
  public.dashboard_stats(),
  public.sales_report(date, date),
  public.customer_stats(uuid)
to authenticated;

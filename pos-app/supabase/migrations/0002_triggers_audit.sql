-- =====================================================================
-- Triggers: updated_at, حماية المخزون، سجل التدقيق
-- =====================================================================

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger products_touch before update on public.products
  for each row execute function public.touch_updated_at();
create trigger customers_touch before update on public.customers
  for each row execute function public.touch_updated_at();
create trigger suppliers_touch before update on public.suppliers
  for each row execute function public.touch_updated_at();
create trigger purchase_orders_touch before update on public.purchase_orders
  for each row execute function public.touch_updated_at();
create trigger store_settings_touch before update on public.store_settings
  for each row execute function public.touch_updated_at();
create trigger variant_costs_touch before update on public.variant_costs
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------
-- المخزون لا يتغير إلا عبر دوال النظام (مبيعات/مرتجعات/مشتريات/تسويات/جرد)
-- ---------------------------------------------------------------------
create or replace function public.guard_variant_stock()
returns trigger language plpgsql as $$
begin
  if new.stock_qty is distinct from old.stock_qty
     and coalesce(current_setting('app.stock_rpc', true), '') <> 'on' then
    raise exception 'لا يمكن تعديل الكمية مباشرة — استخدم تسوية المخزون أو الجرد';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create trigger variants_guard_stock before update on public.product_variants
  for each row execute function public.guard_variant_stock();

-- رصيد افتتاحي + سجل تكلفة عند إنشاء مقاس/لون جديد
create or replace function public.on_variant_created()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.variant_costs (variant_id, cost_price)
  values (new.id, 0) on conflict (variant_id) do nothing;

  if new.stock_qty <> 0 then
    insert into public.stock_movements (variant_id, type, qty_change, balance_after, note)
    values (new.id, 'opening', new.stock_qty, new.stock_qty, 'رصيد افتتاحي');
  end if;
  return new;
end;
$$;

create trigger variants_after_insert after insert on public.product_variants
  for each row execute function public.on_variant_created();

-- تحريك المخزون (داخلي — تستدعيه الدوال فقط)
create or replace function public._move_stock(
  p_variant_id uuid,
  p_qty_change integer,
  p_type public.movement_type,
  p_ref_id uuid,
  p_note text,
  p_check_negative boolean default false
) returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_balance integer;
begin
  perform set_config('app.stock_rpc', 'on', true);

  update public.product_variants
     set stock_qty = stock_qty + p_qty_change
   where id = p_variant_id
  returning stock_qty into v_balance;

  if v_balance is null then
    raise exception 'الصنف غير موجود';
  end if;

  if p_check_negative and v_balance < 0 then
    raise exception 'الكمية غير متوفرة في المخزون (الصنف %)', (select sku from public.product_variants where id = p_variant_id);
  end if;

  insert into public.stock_movements (variant_id, type, qty_change, balance_after, ref_id, note)
  values (p_variant_id, p_type, p_qty_change, v_balance, p_ref_id, p_note);

  perform set_config('app.stock_rpc', 'off', true);
  return v_balance;
end;
$$;
revoke all on function public._move_stock(uuid, integer, public.movement_type, uuid, text, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- إجماليات أمر الشراء
-- ---------------------------------------------------------------------
create or replace function public.recalc_purchase_totals()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_po uuid := coalesce(new.purchase_id, old.purchase_id);
  v_rate numeric := (select vat_rate from public.store_settings where id = 1);
  v_sub numeric;
begin
  select coalesce(sum(qty * unit_cost), 0) into v_sub
    from public.purchase_items where purchase_id = v_po;
  update public.purchase_orders
     set subtotal = round(v_sub, 2),
         vat_amount = round(v_sub * v_rate / 100, 2),
         total = round(v_sub, 2) + round(v_sub * v_rate / 100, 2)
   where id = v_po;
  return null;
end;
$$;

create trigger purchase_items_totals after insert or update or delete on public.purchase_items
  for each row execute function public.recalc_purchase_totals();

-- ---------------------------------------------------------------------
-- Audit log
-- ---------------------------------------------------------------------
create or replace function public.audit_trigger()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_old jsonb;
  v_new jsonb;
  v_changed text[];
begin
  if tg_op in ('UPDATE', 'DELETE') then v_old := to_jsonb(old); end if;
  if tg_op in ('INSERT', 'UPDATE') then v_new := to_jsonb(new); end if;

  if tg_op = 'UPDATE' then
    select array_agg(n.key order by n.key) into v_changed
      from jsonb_each(v_new) n
     where n.value is distinct from (v_old -> n.key)
       and n.key not in ('updated_at', 'stock_qty');
    -- تغيّر المخزون فقط مسجل في حركات المخزون، لا داعي لتكراره
    if v_changed is null then
      return new;
    end if;
  end if;

  insert into public.audit_log (table_name, record_id, action, old_data, new_data, changed_fields)
  values (
    tg_table_name,
    coalesce(v_new ->> 'id', v_old ->> 'id', v_new ->> 'variant_id', v_old ->> 'variant_id'),
    tg_op, v_old, v_new, v_changed
  );
  return coalesce(new, old);
end;
$$;

do $$
declare
  t text;
begin
  foreach t in array array[
    'store_settings', 'profiles', 'categories', 'products', 'product_variants',
    'variant_costs', 'customers', 'suppliers', 'sales', 'sale_payments', 'returns',
    'purchase_orders', 'purchase_items', 'stock_counts'
  ] loop
    execute format(
      'create trigger %I after insert or update or delete on public.%I
         for each row execute function public.audit_trigger()',
      t || '_audit', t);
  end loop;
end;
$$;

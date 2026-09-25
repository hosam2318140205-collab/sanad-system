-- =====================================================================
-- Sales & Customers 2.0 — (3) البيع 2.0
--   • تسعير السلة في الخادم فقط (_price_cart): العروض، الكوبون، خصم الكاشير، استبدال النقاط، الضريبة.
--     نفس الدالة تُستخدم للمعاينة في الشاشة ولإتمام البيع، فلا يختلف ما يراه الكاشير عمّا يُحفظ
--   • complete_sale بمعاملات إضافية اختيارية (التوافق الكامل مع الاستدعاءات السابقة):
--       p_client_ref     : مفتاح منع التكرار — نفس المفتاح يعيد نفس الفاتورة ولا يُنشئ أخرى
--       p_promo_code     : كوبون
--       p_redeem_points  : نقاط تُستبدل كخصم (الضريبة تُحسب بعد الخصم وفق قواعد الهيئة)
--       p_reservation_id : استلام حجز
--     والدفع «آجل» (on_account) لعميل ضمن حد ائتمانه، مع قيد في دفتر الذمم
--   • المرتجع: «إلى حساب العميل» يُنقص الذمة، ونقاط الفاتورة تُعكس بنسبة المرتجع — عبر trigger
--     دون تعديل process_return
--   • رمز عام لكل فاتورة (public_token) لعرضها للعميل واسترجاعها بالـ QR في المرتجع/الاستبدال
-- =====================================================================

alter table public.sales
  add column client_ref uuid unique,
  add column promo_code text,
  add column promo_discount numeric(12,2) not null default 0,
  add column loyalty_points_redeemed integer not null default 0,
  add column loyalty_discount numeric(12,2) not null default 0,     -- بأساس السعر (مثل بقية الخصومات)
  add column loyalty_points_earned integer not null default 0,
  add column reservation_id uuid references public.reservations (id),
  add column public_token text not null unique default replace(gen_random_uuid()::text, '-', '');

alter table public.sale_items
  add column promo_discount numeric(12,2) not null default 0,       -- جزء من line_discount
  add column promotion_id uuid references public.promotions (id) on delete set null;

grant select (promo_discount, promotion_id) on public.sale_items to authenticated;

-- ---------------------------------------------------------------------
-- تقييم عرض واحد على أسطر السلة التي لم يأخذها عرض آخر
--   يعيد: {"total": n, "alloc": [خصم كل سطر], "consumed": [هل السطر محجوز لهذا العرض]}
-- ---------------------------------------------------------------------
create or replace function public._promo_eval(p public.promotions, p_lines jsonb, p_taken boolean[])
returns jsonb
language plpgsql immutable set search_path = public as $$
declare
  n integer := jsonb_array_length(p_lines);
  v_alloc numeric[] := array_fill(0::numeric, array[n]);
  v_cons boolean[] := array_fill(false, array[n]);
  v_units integer := 0;
  v_free integer;
  v_take integer;
  v_total numeric := 0;
  v_line jsonb;
  i integer;
  r record;
begin
  for i in 1 .. n loop
    v_line := p_lines -> (i - 1);
    if not p_taken[i] and (
         p.scope = 'all'
      or (p.scope = 'category' and (v_line ->> 'category_id')::uuid = p.category_id)
      or (p.scope = 'product' and (v_line ->> 'product_id')::uuid = p.product_id)) then
      v_cons[i] := true;
      v_units := v_units + (v_line ->> 'qty')::integer;
    end if;
  end loop;

  if v_units = 0 or v_units < p.min_qty then
    return jsonb_build_object('total', 0);
  end if;

  if p.kind = 'bxgy' then
    v_free := (v_units / (p.buy_qty + p.get_qty)) * p.get_qty;
    if v_free = 0 then
      return jsonb_build_object('total', 0);
    end if;
    -- القطع المجانية = الأرخص بين الأصناف المشمولة
    for r in
      select (x.ord)::integer as idx, (x.l ->> 'qty')::integer as qty, (x.l ->> 'unit_price')::numeric as price
        from jsonb_array_elements(p_lines) with ordinality as x(l, ord)
       order by (x.l ->> 'unit_price')::numeric, x.ord
    loop
      exit when v_free = 0;
      if v_cons[r.idx] then
        v_take := least(r.qty, v_free);
        v_alloc[r.idx] := round(v_take * r.price, 2);
        v_free := v_free - v_take;
      end if;
    end loop;
  else
    for i in 1 .. n loop
      if v_cons[i] then
        v_line := p_lines -> (i - 1);
        if p.kind = 'percent' then
          v_alloc[i] := round((v_line ->> 'gross')::numeric * p.value / 100, 2);
        else
          v_alloc[i] := least(round(p.value * (v_line ->> 'qty')::integer, 2), (v_line ->> 'gross')::numeric);
        end if;
      end if;
    end loop;
    -- عروض النسبة/المبلغ لا تحجز إلا الأسطر التي خُصم منها فعلاً
    for i in 1 .. n loop
      v_cons[i] := v_cons[i] and v_alloc[i] > 0;
    end loop;
  end if;

  for i in 1 .. n loop
    v_total := v_total + v_alloc[i];
  end loop;
  return jsonb_build_object('total', v_total, 'alloc', to_jsonb(v_alloc), 'consumed', to_jsonb(v_cons));
end;
$$;
revoke all on function public._promo_eval(public.promotions, jsonb, boolean[]) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- تسعير السلة (داخلي). لا يكتب شيئاً.
-- ترتيب الخصومات على كل سطر: العرض (الأفضل للعميل، بلا تراكب عروض) ← خصم الكاشير على السطر
-- ثم على الفاتورة: خصم الكاشير + قيمة النقاط، موزعة على الأسطر نسبياً، ثم الضريبة لكل سطر
-- ---------------------------------------------------------------------
create or replace function public._price_cart(
  p_items jsonb,
  p_invoice_discount numeric,
  p_promo_code text,
  p_redeem_points integer,
  p_customer_id uuid,
  p_role public.user_role
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  s public.store_settings;
  v_item jsonb;
  v_variant record;
  v_lines jsonb := '[]'::jsonb;
  v_line jsonb;
  n integer;
  i integer;
  v_qty integer;
  v_code text := nullif(upper(trim(p_promo_code)), '');
  v_code_applied boolean := false;
  v_taken boolean[];
  v_promo public.promotions;
  v_eval jsonb;
  v_best jsonb;
  v_best_promo public.promotions;
  v_best_total numeric;
  v_applied jsonb := '[]'::jsonb;
  v_gross numeric;
  v_promo_amt numeric;
  v_disc numeric;
  v_sum_gross numeric := 0;
  v_sum_promo numeric := 0;
  v_sum_manual numeric := 0;
  v_base numeric;
  v_inv_disc numeric;
  v_points integer := greatest(coalesce(p_redeem_points, 0), 0);
  v_loyalty_value numeric := 0;
  v_loyalty_base numeric := 0;
  v_loyalty_cap numeric;
  v_alloc_total numeric;
  v_alloc numeric;
  v_alloc_done numeric := 0;
  v_net numeric;
  v_line_total numeric;
  v_line_vat numeric;
  v_total numeric := 0;
  v_vat numeric := 0;
begin
  select * into s from public.store_settings where id = 1;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'السلة فارغة';
  end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty := (v_item ->> 'qty')::integer;
    if v_qty is null or v_qty <= 0 then
      raise exception 'كمية غير صحيحة';
    end if;
    select v.id, v.sku, v.size, v.color, coalesce(v.price, p.base_price) as price, p.name, p.id as product_id,
           p.category_id, v.is_active and p.is_active as active, coalesce(c.cost_price, 0) as cost
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
    v_lines := v_lines || jsonb_build_object(
      'variant_id', v_variant.id, 'sku', v_variant.sku, 'product_name', v_variant.name,
      'variant_label', nullif(concat_ws(' / ', v_variant.size, v_variant.color), ''),
      'product_id', v_variant.product_id, 'category_id', v_variant.category_id,
      'qty', v_qty, 'unit_price', v_variant.price, 'gross', round(v_variant.price * v_qty, 2),
      'manual', greatest(coalesce((v_item ->> 'discount')::numeric, 0), 0), 'cost', v_variant.cost,
      'promo', 0, 'promotion_id', null);
  end loop;
  n := jsonb_array_length(v_lines);
  v_taken := array_fill(false, array[n]);

  -- الكوبون يجب أن يكون صالحاً الآن
  if v_code is not null and not exists (
    select 1 from public.promotions
     where code = v_code and is_active
       and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at > now())) then
    raise exception 'رمز الخصم «%» غير صالح أو منتهي الصلاحية', v_code;
  end if;

  -- اختيار العروض: كل جولة تأخذ العرض الأكبر خصماً على الأسطر المتبقية (بلا تراكب على نفس السطر)
  loop
    v_best := null;
    v_best_total := 0;
    for v_promo in
      select * from public.promotions
       where is_active
         and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at > now())
         and (code is null or code = v_code)
       order by created_at, id
    loop
      v_eval := public._promo_eval(v_promo, v_lines, v_taken);
      if (v_eval ->> 'total')::numeric > v_best_total then
        v_best := v_eval;
        v_best_total := (v_eval ->> 'total')::numeric;
        v_best_promo := v_promo;
      end if;
    end loop;
    exit when v_best is null;

    for i in 1 .. n loop
      if (v_best -> 'consumed' ->> (i - 1))::boolean then
        v_taken[i] := true;
        v_lines := jsonb_set(v_lines, array[(i - 1)::text], (v_lines -> (i - 1)) || jsonb_build_object(
          'promo', (v_best -> 'alloc' ->> (i - 1))::numeric,
          'promotion_id', case when (v_best -> 'alloc' ->> (i - 1))::numeric > 0 then v_best_promo.id end));
      end if;
    end loop;
    v_applied := v_applied || jsonb_build_object('id', v_best_promo.id, 'name', v_best_promo.name,
                                                 'code', v_best_promo.code, 'discount', v_best_total);
    if v_best_promo.code is not null then
      v_code_applied := true;
    end if;
  end loop;

  -- خصم الكاشير على السطر: لا يتجاوز ما بقي بعد العرض
  for i in 0 .. n - 1 loop
    v_line := v_lines -> i;
    v_gross := (v_line ->> 'gross')::numeric;
    v_promo_amt := (v_line ->> 'promo')::numeric;
    v_disc := round(least((v_line ->> 'manual')::numeric, v_gross - v_promo_amt), 2);
    v_lines := jsonb_set(v_lines, array[i::text], v_line || jsonb_build_object('manual', v_disc));
    v_sum_gross := v_sum_gross + v_gross;
    v_sum_promo := v_sum_promo + v_promo_amt;
    v_sum_manual := v_sum_manual + v_disc;
  end loop;

  v_base := v_sum_gross - v_sum_promo - v_sum_manual;
  v_inv_disc := round(least(greatest(coalesce(p_invoice_discount, 0), 0), v_base), 2);

  -- حد الخصم للكاشير: يشمل خصوماته اليدوية فقط (العروض والنقاط خصومات النظام)
  if p_role = 'cashier' and v_sum_gross > 0
     and (v_sum_manual + v_inv_disc) / v_sum_gross * 100 > s.max_cashier_discount_pct + 0.001 then
    raise exception 'الخصم يتجاوز الحد المسموح للكاشير (% %%)', s.max_cashier_discount_pct;
  end if;

  -- استبدال النقاط
  if v_points > 0 then
    if not s.loyalty_enabled then
      raise exception 'برنامج الولاء غير مفعّل';
    end if;
    if p_customer_id is null then
      raise exception 'اختر العميل لاستبدال النقاط';
    end if;
    if v_points < s.loyalty_min_redeem then
      raise exception 'الحد الأدنى للاستبدال % نقطة', s.loyalty_min_redeem;
    end if;
    if v_points > coalesce((select loyalty_points from public.customer_accounts where customer_id = p_customer_id), 0) then
      raise exception 'رصيد النقاط غير كافٍ';
    end if;
    v_loyalty_value := round(v_points * s.loyalty_point_value, 2);
    v_loyalty_base := case when s.prices_include_vat then v_loyalty_value
                           else round(v_loyalty_value * 100 / (100 + s.vat_rate), 2) end;
    v_loyalty_cap := round((v_base - v_inv_disc) * s.loyalty_max_redeem_pct / 100, 2);
    if v_loyalty_base > v_loyalty_cap + 0.001 then
      raise exception 'قيمة النقاط (% ر.س) تتجاوز الحد المسموح (% %% من الفاتورة)', v_loyalty_value, s.loyalty_max_redeem_pct;
    end if;
  end if;

  -- توزيع خصم الفاتورة + النقاط على الأسطر، ثم الضريبة (نفس خوارزمية complete_sale السابقة)
  v_alloc_total := v_inv_disc + v_loyalty_base;
  for i in 0 .. n - 1 loop
    v_line := v_lines -> i;
    v_net := (v_line ->> 'gross')::numeric - (v_line ->> 'promo')::numeric - (v_line ->> 'manual')::numeric;
    if i = n - 1 then
      v_alloc := v_alloc_total - v_alloc_done;
    elsif v_base > 0 then
      v_alloc := round(v_alloc_total * v_net / v_base, 2);
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
    v_lines := jsonb_set(v_lines, array[i::text], v_line || jsonb_build_object(
      'line_discount', (v_line ->> 'manual')::numeric + (v_line ->> 'promo')::numeric + v_alloc,
      'line_total', v_line_total,
      'vat', v_line_vat));
  end loop;

  return jsonb_build_object(
    'lines', v_lines,
    'gross', v_sum_gross,
    'promo_discount', v_sum_promo,
    'manual_discount', v_sum_manual,
    'invoice_discount', v_inv_disc,
    'loyalty_points', v_points,
    'loyalty_value', v_loyalty_value,
    'loyalty_discount', v_loyalty_base,
    'discount_total', v_sum_promo + v_sum_manual + v_inv_disc + v_loyalty_base,
    'subtotal', v_total - v_vat,
    'vat', v_vat,
    'total', v_total,
    'promotions', v_applied,
    'promo_code', v_code,
    'promo_code_applied', v_code_applied
  );
end;
$$;
revoke all on function public._price_cart(jsonb, numeric, text, integer, uuid, public.user_role) from public, anon, authenticated;

-- معاينة السلة للشاشة (نفس حسابات إتمام البيع) + ما يحتاجه الكاشير عن العميل
create or replace function public.price_cart(
  p_items jsonb,
  p_invoice_discount numeric default 0,
  p_promo_code text default null,
  p_redeem_points integer default 0,
  p_customer_id uuid default null
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_role public.user_role := public.current_user_role();
  s public.store_settings;
  v_acc public.customer_accounts;
  v_result jsonb;
begin
  if v_role is null then
    raise exception 'غير مصرح';
  end if;
  select * into s from public.store_settings where id = 1;
  v_result := public._price_cart(p_items, p_invoice_discount, p_promo_code, p_redeem_points, p_customer_id, v_role);
  if p_customer_id is not null then
    select * into v_acc from public.customer_accounts where customer_id = p_customer_id;
    v_result := v_result || jsonb_build_object('customer', jsonb_build_object(
      'loyalty_points', coalesce(v_acc.loyalty_points, 0),
      'account_balance', coalesce(v_acc.account_balance, 0),
      'credit_limit', v_acc.credit_limit,
      'credit_available', greatest(coalesce(v_acc.credit_limit, 0) - coalesce(v_acc.account_balance, 0), 0),
      'can_use_credit', (v_role <> 'cashier' or s.allow_cashier_credit)
    ));
  end if;
  -- قطع لا يمكن بيعها لأنها محجوزة لعملاء آخرين
  return v_result || jsonb_build_object('reserved', coalesce((
    select jsonb_object_agg(l ->> 'variant_id', public._reserved_qty((l ->> 'variant_id')::uuid))
      from jsonb_array_elements(v_result -> 'lines') l
     where public._reserved_qty((l ->> 'variant_id')::uuid) > 0), '{}'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------
-- إتمام البيع 2.0 — يحل محل النسخة السابقة بنفس المعاملات الخمسة الأولى
-- ---------------------------------------------------------------------
drop function public.complete_sale(jsonb, jsonb, uuid, numeric, text);

create or replace function public.complete_sale(
  p_items jsonb,
  p_payments jsonb,
  p_customer_id uuid default null,
  p_invoice_discount numeric default 0,
  p_notes text default null,
  p_client_ref uuid default null,
  p_promo_code text default null,
  p_redeem_points integer default 0,
  p_reservation_id uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role public.user_role := public.current_user_role();
  s public.store_settings;
  v_existing public.sales;
  v_res public.reservations;
  v_customer uuid := p_customer_id;
  v_acc public.customer_accounts;
  v_price jsonb;
  v_line jsonb;
  v_pay jsonb;
  v_sale_id uuid;
  v_invoice_no text;
  v_total numeric;
  v_paid numeric := 0;
  v_noncash numeric := 0;
  v_on_account numeric := 0;
  v_exchange numeric := 0;
  v_change numeric;
  v_method public.payment_method;
  v_amount numeric;
  v_return public.returns;
  v_points integer := greatest(coalesce(p_redeem_points, 0), 0);
  v_earn integer := 0;
  v_available integer;
begin
  if v_role is null then
    raise exception 'غير مصرح';
  end if;
  select * into s from public.store_settings where id = 1;

  -- منع الترحيل المزدوج: نفس المفتاح = نفس الفاتورة
  if p_client_ref is not null then
    select * into v_existing from public.sales where client_ref = p_client_ref;
    if v_existing.id is not null then
      if v_existing.cashier_id is distinct from auth.uid() then
        raise exception 'مرجع العملية مستخدم مسبقاً';
      end if;
      return v_existing.id;
    end if;
  end if;

  -- استلام حجز
  if p_reservation_id is not null then
    select * into v_res from public.reservations where id = p_reservation_id for update;
    if v_res.id is null or v_res.status <> 'active' then
      raise exception 'الحجز غير موجود أو تم إغلاقه';
    end if;
    if v_customer is null then
      v_customer := v_res.customer_id;
    elsif v_customer <> v_res.customer_id then
      raise exception 'الحجز لعميل آخر';
    end if;
  end if;

  if v_customer is not null and not exists (select 1 from public.customers where id = v_customer) then
    raise exception 'العميل غير موجود';
  end if;
  -- قفل حساب العميل قبل التحقق من النقاط/الائتمان
  if v_customer is not null then
    v_acc := public._customer_account(v_customer);
  end if;

  v_price := public._price_cart(p_items, p_invoice_discount, p_promo_code, v_points, v_customer, v_role);
  v_total := (v_price ->> 'total')::numeric;

  -- الكميات المحجوزة لعملاء آخرين لا تُباع
  if not s.allow_negative_stock then
    for v_line in
      select jsonb_build_object('variant_id', l ->> 'variant_id', 'sku', min(l ->> 'sku'), 'qty', sum((l ->> 'qty')::integer))
        from jsonb_array_elements(v_price -> 'lines') l group by l ->> 'variant_id'
    loop
      select stock_qty - public._reserved_qty(id, p_reservation_id) into v_available
        from public.product_variants where id = (v_line ->> 'variant_id')::uuid for update;
      if (v_line ->> 'qty')::integer > v_available then
        raise exception 'المتاح من الصنف % هو % فقط (الباقي محجوز لعملاء)', v_line ->> 'sku', greatest(v_available, 0);
      end if;
    end loop;
  end if;

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
      select * into v_return from public.returns where id = (v_pay ->> 'return_id')::uuid for update;
      if v_return.id is null or v_return.refund_method <> 'exchange' then
        raise exception 'رصيد الاستبدال غير صالح';
      end if;
      if v_return.credit_used_by_sale is not null then
        raise exception 'رصيد الاستبدال % مستخدم مسبقاً', v_return.return_no;
      end if;
      if v_amount <> v_return.total then
        raise exception 'يجب استخدام رصيد الاستبدال كاملاً (% ر.س)', v_return.total;
      end if;
      v_exchange := v_exchange + v_amount;
    elsif v_method = 'on_account' then
      v_on_account := v_on_account + v_amount;
    end if;
    if v_method = 'cash' then
      null;
    else
      v_noncash := v_noncash + v_amount;
    end if;
    v_paid := v_paid + v_amount;
  end loop;

  if v_noncash > v_total + 0.001 then
    raise exception 'مبالغ الشبكة/التحويل/الاستبدال/الآجل (% ) أكبر من إجمالي الفاتورة (% )', v_noncash, v_total;
  end if;
  if v_paid + 0.001 < v_total then
    raise exception 'المبلغ المدفوع (% ) أقل من الإجمالي (% )', v_paid, v_total;
  end if;
  v_change := round(v_paid - v_total, 2);

  -- البيع الآجل
  if v_on_account > 0 then
    if v_customer is null then
      raise exception 'البيع الآجل يتطلب اختيار العميل';
    end if;
    if v_role = 'cashier' and not s.allow_cashier_credit then
      raise exception 'البيع الآجل غير مسموح للكاشير';
    end if;
    if v_acc.account_balance + v_on_account > coalesce(v_acc.credit_limit, 0) + 0.001 then
      raise exception 'يتجاوز حد الائتمان للعميل (الحد % ر.س، الرصيد الحالي % ر.س)',
        coalesce(v_acc.credit_limit, 0), v_acc.account_balance;
    end if;
  end if;

  v_invoice_no := 'INV-' || to_char(now() at time zone 'Asia/Riyadh', 'YY') || lpad(nextval('public.invoice_seq')::text, 6, '0');
  insert into public.sales (
    invoice_no, customer_id, cashier_id, subtotal, discount_total, invoice_discount,
    vat_rate, vat_amount, total, paid_amount, change_amount, notes,
    client_ref, promo_code, promo_discount, loyalty_points_redeemed, loyalty_discount, reservation_id
  ) values (
    v_invoice_no, v_customer, auth.uid(), (v_price ->> 'subtotal')::numeric, (v_price ->> 'discount_total')::numeric,
    (v_price ->> 'invoice_discount')::numeric, s.vat_rate, (v_price ->> 'vat')::numeric, v_total, v_paid, v_change,
    nullif(trim(p_notes), ''),
    p_client_ref, case when (v_price ->> 'promo_code_applied')::boolean then v_price ->> 'promo_code' end,
    (v_price ->> 'promo_discount')::numeric, v_points, (v_price ->> 'loyalty_discount')::numeric, p_reservation_id
  ) returning id into v_sale_id;

  insert into public.sale_items (
    sale_id, variant_id, product_name, variant_label, sku, qty, unit_price,
    line_discount, line_total, vat_amount, unit_cost, promo_discount, promotion_id
  )
  select v_sale_id, (l ->> 'variant_id')::uuid, l ->> 'product_name', l ->> 'variant_label',
         l ->> 'sku', (l ->> 'qty')::integer, (l ->> 'unit_price')::numeric,
         (l ->> 'line_discount')::numeric, (l ->> 'line_total')::numeric,
         (l ->> 'vat')::numeric, (l ->> 'cost')::numeric,
         (l ->> 'promo')::numeric, (l ->> 'promotion_id')::uuid
    from jsonb_array_elements(v_price -> 'lines') l;

  for v_line in select * from jsonb_array_elements(v_price -> 'lines') loop
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
      update public.returns set credit_used_by_sale = v_sale_id where id = (v_pay ->> 'return_id')::uuid;
    end if;
  end loop;

  -- الذمم: قيد مدين بالمبلغ الآجل (قيد واحد لكل فاتورة — القيد الفريد يمنع التكرار)
  if v_on_account > 0 then
    perform public._post_ar(v_customer, 'sale', v_sale_id, v_invoice_no, v_on_account, 0, null);
  end if;

  -- الولاء: خصم المستبدل، ثم كسب نقاط على المدفوع فعلاً: بدون رصيد الاستبدال، وبدون الآجل
  -- إلا ما غطّاه رصيد دائن سابق للعميل (عربون مدفوع مسبقاً = مدفوع فعلاً)
  if v_customer is not null then
    if v_points > 0 then
      perform public._post_loyalty(v_customer, 'redeem', v_sale_id, v_invoice_no, -v_points, null);
    end if;
    if s.loyalty_enabled then
      v_earn := floor(greatest(
        v_total - v_exchange - (v_on_account - least(v_on_account, greatest(-v_acc.account_balance, 0))), 0)
        * s.loyalty_points_per_sar)::integer;
      if v_earn > 0 then
        perform public._post_loyalty(v_customer, 'earn', v_sale_id, v_invoice_no, v_earn, null);
        update public.sales set loyalty_points_earned = v_earn where id = v_sale_id;
      end if;
    end if;
  end if;

  if p_reservation_id is not null then
    update public.reservations
       set status = 'fulfilled', sale_id = v_sale_id, closed_at = now(), closed_by = auth.uid()
     where id = p_reservation_id;
  end if;

  return v_sale_id;
end;
$$;

-- ---------------------------------------------------------------------
-- المرتجع: ربط الذمم والنقاط (بعد أن يحدد process_return إجمالي المرتجع)
-- ---------------------------------------------------------------------
create or replace function public.on_return_posted()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_sale public.sales;
  v_on_account numeric;
  v_paid_now numeric;
  v_prev numeric;
  v_earned integer;
  v_redeemed integer;
  v_done integer;
  v_ratio numeric;
  v_delta integer;
begin
  select * into v_sale from public.sales where id = new.sale_id;

  if new.refund_method = 'account' then
    if v_sale.customer_id is null then
      raise exception 'الإرجاع إلى الحساب يتطلب فاتورة باسم عميل';
    end if;
    perform public._post_ar(v_sale.customer_id, 'return', new.id, new.return_no, 0, new.total, v_sale.invoice_no);
  else
    -- فاتورة فيها جزء آجل: لا يُرد نقداً/شبكة/استبدال أكثر مما دُفع فعلاً عند البيع
    select coalesce(sum(amount) filter (where method = 'on_account'), 0),
           coalesce(sum(amount) filter (where method <> 'on_account'), 0) - v_sale.change_amount
      into v_on_account, v_paid_now
      from public.sale_payments where sale_id = v_sale.id;
    if v_on_account > 0 then
      select coalesce(sum(total), 0) into v_prev from public.returns
       where sale_id = v_sale.id and id <> new.id and refund_method <> 'account';
      if v_prev + new.total > v_paid_now + 0.001 then
        raise exception 'جزء من هذه الفاتورة آجل: الحد الأقصى للرد بهذه الطريقة % ر.س — اختر «إلى حساب العميل»',
          greatest(v_paid_now - v_prev, 0);
      end if;
    end if;
  end if;

  -- النقاط: عكس المكتسب واسترجاع المستبدل بنسبة ما أُرجع من الفاتورة (تراكمياً لتفادي فروق التقريب)
  if v_sale.customer_id is not null and v_sale.total > 0 then
    v_ratio := least((select coalesce(sum(total), 0) from public.returns where sale_id = v_sale.id) / v_sale.total, 1);
    select coalesce(sum(points), 0) into v_earned from public.loyalty_ledger
     where entry_type = 'earn' and source_id = v_sale.id;
    select -coalesce(sum(points), 0) into v_redeemed from public.loyalty_ledger
     where entry_type = 'redeem' and source_id = v_sale.id;

    if v_earned > 0 then
      select -coalesce(sum(l.points), 0) into v_done from public.loyalty_ledger l
        join public.returns r on r.id = l.source_id
       where l.entry_type = 'return_reverse' and r.sale_id = v_sale.id;
      v_delta := round(v_earned * v_ratio)::integer - v_done;
      if v_delta > 0 then
        perform public._post_loyalty(v_sale.customer_id, 'return_reverse', new.id, new.return_no, -v_delta, v_sale.invoice_no);
      end if;
    end if;
    if v_redeemed > 0 then
      select coalesce(sum(l.points), 0) into v_done from public.loyalty_ledger l
        join public.returns r on r.id = l.source_id
       where l.entry_type = 'return_restore' and r.sale_id = v_sale.id;
      v_delta := round(v_redeemed * v_ratio)::integer - v_done;
      if v_delta > 0 then
        perform public._post_loyalty(v_sale.customer_id, 'return_restore', new.id, new.return_no, v_delta, v_sale.invoice_no);
      end if;
    end if;
  end if;
  return new;
end;
$$;

create trigger returns_posted after update of total on public.returns
  for each row when (old.total = 0 and new.total > 0)
  execute function public.on_return_posted();

-- ---------------------------------------------------------------------
-- الفاتورة للعميل برابط/QR (بدون تسجيل دخول) — بيانات الفاتورة فقط، دون بيانات العميل أو التكلفة
-- ---------------------------------------------------------------------
create or replace function public.public_receipt(p_token text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v public.sales;
  s public.store_settings;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{32}$' then
    return null;
  end if;
  select * into v from public.sales where public_token = p_token;
  if v.id is null then
    return null;
  end if;
  select * into s from public.store_settings where id = 1;
  return jsonb_build_object(
    'store', jsonb_build_object('name', s.store_name, 'name_en', s.store_name_en, 'vat_number', s.vat_number,
                                'cr_number', s.cr_number, 'phone', s.phone, 'address', s.address,
                                'footer', s.receipt_footer, 'prices_include_vat', s.prices_include_vat),
    'invoice_no', v.invoice_no, 'created_at', v.created_at, 'status', v.status,
    'subtotal', v.subtotal, 'discount_total', v.discount_total, 'vat_rate', v.vat_rate, 'vat_amount', v.vat_amount,
    'total', v.total, 'paid_amount', v.paid_amount, 'change_amount', v.change_amount,
    'returned_amount', v.returned_amount, 'loyalty_points_earned', v.loyalty_points_earned,
    'items', coalesce((select jsonb_agg(jsonb_build_object(
               'product_name', i.product_name, 'variant_label', i.variant_label, 'qty', i.qty,
               'unit_price', i.unit_price, 'line_discount', i.line_discount, 'line_total', i.line_total,
               'returned_qty', i.returned_qty) order by i.product_name)
               from public.sale_items i where i.sale_id = v.id), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('method', p.method, 'amount', p.amount))
               from public.sale_payments p where p.sale_id = v.id), '[]'::jsonb)
  );
end;
$$;

-- استرجاع رقم الفاتورة من: رقم الفاتورة، أو الرمز، أو رابط QR (للمرتجع/الاستبدال)
create or replace function public.resolve_invoice_ref(p_ref text)
returns text
language plpgsql stable security definer set search_path = public as $$
declare
  v_ref text := trim(coalesce(p_ref, ''));
  v_token text;
  v_no text;
begin
  if not public.is_staff() then
    raise exception 'غير مصرح';
  end if;
  v_token := substring(v_ref from '([0-9a-f]{32})');
  if v_token is not null then
    select invoice_no into v_no from public.sales where public_token = v_token;
  end if;
  if v_no is null then
    select invoice_no into v_no from public.sales where upper(invoice_no) = upper(v_ref);
  end if;
  if v_no is null then
    raise exception 'الفاتورة غير موجودة';
  end if;
  return v_no;
end;
$$;

-- سياق المرتجع: العميل والجزء الآجل ونقاط الفاتورة (لشاشة المرتجعات — بنفس صلاحية get_sale_for_return)
create or replace function public.sale_return_context(p_sale_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_role public.user_role := public.current_user_role();
  s public.store_settings;
  v public.sales;
  v_on_account numeric;
  v_paid_now numeric;
  v_refunded numeric;
begin
  select * into s from public.store_settings where id = 1;
  if v_role is null or (v_role = 'cashier' and not s.allow_cashier_returns) then
    raise exception 'غير مصرح بعمليات الإرجاع';
  end if;
  select * into v from public.sales where id = p_sale_id;
  if v.id is null then
    raise exception 'الفاتورة غير موجودة';
  end if;
  select coalesce(sum(amount) filter (where method::text = 'on_account'), 0),
         coalesce(sum(amount) filter (where method::text <> 'on_account'), 0) - v.change_amount
    into v_on_account, v_paid_now
    from public.sale_payments where sale_id = v.id;
  select coalesce(sum(total), 0) into v_refunded from public.returns
   where sale_id = v.id and refund_method::text <> 'account';
  return jsonb_build_object(
    'customer_id', v.customer_id,
    'customer_phone', (select phone from public.customers where id = v.customer_id),
    'on_account', v_on_account,
    'max_direct_refund', case when v_on_account > 0 then greatest(v_paid_now - v_refunded, 0) end,
    'loyalty_points_earned', v.loyalty_points_earned,
    'loyalty_points_redeemed', v.loyalty_points_redeemed
  );
end;
$$;

-- ---------------------------------------------------------------------
-- سجل رسائل واتساب (فتح المحادثة من النظام)
-- ---------------------------------------------------------------------
create table public.message_log (
  id uuid primary key default gen_random_uuid(),
  channel text not null default 'whatsapp' check (channel in ('whatsapp')),
  kind text not null check (kind in ('receipt', 'statement', 'reservation', 'reminder')),
  sale_id uuid references public.sales (id) on delete set null,
  customer_id uuid references public.customers (id) on delete set null,
  reservation_id uuid references public.reservations (id) on delete set null,
  phone text not null check (phone ~ '^[0-9]{8,15}$'),
  created_by uuid not null references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now()
);
create index message_log_customer_idx on public.message_log (customer_id, created_at desc);
create index message_log_sale_idx on public.message_log (sale_id);

alter table public.message_log enable row level security;
revoke all on public.message_log from anon;
revoke update, delete on public.message_log from authenticated;
grant select, insert on public.message_log to authenticated;
create policy message_log_select on public.message_log for select to authenticated using (public.is_staff());
create policy message_log_insert on public.message_log for insert to authenticated
  with check (public.is_staff() and created_by = auth.uid());

-- ---------------------------------------------------------------------
-- الصلاحيات
-- ---------------------------------------------------------------------
revoke execute on function
  public.complete_sale(jsonb, jsonb, uuid, numeric, text, uuid, text, integer, uuid),
  public.price_cart(jsonb, numeric, text, integer, uuid),
  public.resolve_invoice_ref(text),
  public.sale_return_context(uuid),
  public.public_receipt(text),
  public.on_return_posted()
from public, anon;
grant execute on function
  public.complete_sale(jsonb, jsonb, uuid, numeric, text, uuid, text, integer, uuid),
  public.price_cart(jsonb, numeric, text, integer, uuid),
  public.resolve_invoice_ref(text),
  public.sale_return_context(uuid)
to authenticated;
-- الرابط العام للفاتورة: للزائر والمسجل
grant execute on function public.public_receipt(text) to anon, authenticated;

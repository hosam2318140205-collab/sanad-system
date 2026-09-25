-- =====================================================================
-- Sales & Customers 2.0 — (4) ملف العميل الشامل + تحليلات العملاء
--   قراءة فقط. لا تكلفة ولا أرباح في ملف العميل (يراه الكاشير أيضاً).
-- =====================================================================

create or replace function public.customer_profile(p_customer_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_c public.customers;
begin
  if not public.is_staff() then
    raise exception 'غير مصرح';
  end if;
  select * into v_c from public.customers where id = p_customer_id;
  if v_c.id is null then
    raise exception 'العميل غير موجود';
  end if;

  return (
    with s as (select * from public.sales where customer_id = p_customer_id),
    items as (
      select i.*, v.size, v.color, c.name as category
        from public.sale_items i
        join s on s.id = i.sale_id
        join public.product_variants v on v.id = i.variant_id
        join public.products p on p.id = v.product_id
        left join public.categories c on c.id = p.category_id
    )
    select jsonb_build_object(
      'customer', to_jsonb(v_c),
      'account', (select jsonb_build_object('account_balance', coalesce(a.account_balance, 0),
                                            'credit_limit', a.credit_limit,
                                            'loyalty_points', coalesce(a.loyalty_points, 0))
                    from (select 1) x left join public.customer_accounts a on a.customer_id = p_customer_id),
      'stats', (select jsonb_build_object(
                  'invoices', count(*),
                  'gross_spent', coalesce(sum(total), 0),
                  'returned', coalesce(sum(returned_amount), 0),
                  'net_spent', coalesce(sum(total - returned_amount), 0),
                  'avg_basket', case when count(*) > 0 then round(sum(total - returned_amount) / count(*), 2) else 0 end,
                  'first_purchase', min(created_at),
                  'last_purchase', max(created_at),
                  'days_since_last', (now() at time zone 'Asia/Riyadh')::date - (max(created_at) at time zone 'Asia/Riyadh')::date,
                  'units', coalesce((select sum(qty - returned_qty) from items), 0),
                  'promo_savings', coalesce(sum(promo_discount), 0),
                  'points_redeemed', coalesce(sum(loyalty_points_redeemed), 0)
                ) from s),
      'favorite_sizes', coalesce((select jsonb_agg(x) from (
          select size as label, sum(qty - returned_qty) as units from items where size is not null
           group by size having sum(qty - returned_qty) > 0 order by 2 desc, 1 limit 3) x), '[]'::jsonb),
      'favorite_colors', coalesce((select jsonb_agg(x) from (
          select color as label, sum(qty - returned_qty) as units from items where color is not null
           group by color having sum(qty - returned_qty) > 0 order by 2 desc, 1 limit 3) x), '[]'::jsonb),
      'favorite_categories', coalesce((select jsonb_agg(x) from (
          select category as label, sum(qty - returned_qty) as units from items where category is not null
           group by category having sum(qty - returned_qty) > 0 order by 2 desc, 1 limit 3) x), '[]'::jsonb),
      'purchases', coalesce((select jsonb_agg(x order by x.created_at desc) from (
          select s.id, s.invoice_no, s.created_at, s.total, s.returned_amount, s.status, s.public_token,
                 s.cashier_id = auth.uid() as is_mine,
                 (select sum(qty) from public.sale_items where sale_id = s.id) as units,
                 (select string_agg(distinct method::text, ',') from public.sale_payments where sale_id = s.id) as methods,
                 (select string_agg(product_name || coalesce(' ' || variant_label, ''), '، ' order by product_name)
                    from public.sale_items where sale_id = s.id) as summary
            from s order by s.created_at desc limit 50) x), '[]'::jsonb),
      'reservations', coalesce((select jsonb_agg(x order by x.created_at desc) from (
          select r.id, r.reservation_no, r.status, r.expires_at, r.created_at, r.notes,
                 r.status = 'active' and r.expires_at <= now() as expired,
                 (select jsonb_agg(jsonb_build_object('variant_id', i.variant_id, 'qty', i.qty, 'sku', v.sku,
                                                      'product_name', p.name,
                                                      'variant_label', nullif(concat_ws(' / ', v.size, v.color), '')))
                    from public.reservation_items i
                    join public.product_variants v on v.id = i.variant_id
                    join public.products p on p.id = v.product_id
                   where i.reservation_id = r.id) as items
            from public.reservations r where r.customer_id = p_customer_id
           order by r.created_at desc limit 20) x), '[]'::jsonb),
      'loyalty', coalesce((select jsonb_agg(x order by x.id desc) from (
          select id, entry_type, ref_no, points, balance_after, note, created_at
            from public.loyalty_ledger where customer_id = p_customer_id order by id desc limit 30) x), '[]'::jsonb),
      'messages', (select count(*) from public.message_log where customer_id = p_customer_id)
    )
  );
end;
$$;

-- ---------------------------------------------------------------------
-- تحليلات العملاء (للمدير)
-- الشرائح بقواعد واضحة (R = أيام منذ آخر شراء، F = عدد الفواتير آخر 365 يوماً):
--   مميز: R ≤ 30 و F ≥ 4 | وفيّ: R ≤ 60 و F ≥ 2 | جديد: أول شراء خلال 30 يوماً
--   معرّض للفقد: 60 < R ≤ 120 و F ≥ 2 | مفقود: R > 120 | عرضي: غير ذلك
-- ---------------------------------------------------------------------
create or replace function public.customer_analytics(p_from date, p_to date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_from timestamptz := p_from::timestamp at time zone 'Asia/Riyadh';
  v_to timestamptz := (p_to + 1)::timestamp at time zone 'Asia/Riyadh';
  s public.store_settings;
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'الفترة غير صحيحة';
  end if;
  select * into s from public.store_settings where id = 1;

  return (
    with ps as (select * from public.sales where created_at >= v_from and created_at < v_to),
    per_customer as (
      select customer_id, count(*) as invoices, sum(total - returned_amount) as net, max(created_at) as last_at
        from ps where customer_id is not null group by customer_id
    ),
    life as (
      select customer_id, min(created_at) as first_at, max(created_at) as last_at,
             count(*) filter (where created_at >= now() - interval '365 days') as f365,
             sum(total - returned_amount) filter (where created_at >= now() - interval '365 days') as m365
        from public.sales where customer_id is not null group by customer_id
    ),
    seg as (
      select l.*,
             (now() at time zone 'Asia/Riyadh')::date - (l.last_at at time zone 'Asia/Riyadh')::date as r,
             case
               when now() - l.last_at <= interval '30 days' and l.f365 >= 4 then 'champions'
               when now() - l.last_at <= interval '60 days' and l.f365 >= 2 then 'loyal'
               when now() - l.first_at <= interval '30 days' then 'new'
               when now() - l.last_at > interval '60 days' and now() - l.last_at <= interval '120 days' and l.f365 >= 2 then 'at_risk'
               when now() - l.last_at > interval '120 days' then 'lost'
               else 'occasional'
             end as segment
        from life l
    )
    select jsonb_build_object(
      'from', p_from, 'to', p_to,
      'customers_total', (select count(*) from public.customers),
      'customers_new', (select count(*) from public.customers where created_at >= v_from and created_at < v_to),
      'customers_active', (select count(*) from per_customer),
      'customers_returning', (select count(*) from per_customer pc join life l on l.customer_id = pc.customer_id
                               where l.first_at < v_from),
      'repeat_rate', case when (select count(*) from per_customer) > 0
                          then round(100.0 * (select count(*) from per_customer where invoices >= 2)
                                     / (select count(*) from per_customer), 1) else 0 end,
      'sales_registered', coalesce((select sum(total - returned_amount) from ps where customer_id is not null), 0),
      'sales_walkin', coalesce((select sum(total - returned_amount) from ps where customer_id is null), 0),
      'invoices_registered', (select count(*) from ps where customer_id is not null),
      'invoices_walkin', (select count(*) from ps where customer_id is null),
      'avg_basket_registered', coalesce((select round(avg(total - returned_amount), 2) from ps where customer_id is not null), 0),
      'avg_basket_walkin', coalesce((select round(avg(total - returned_amount), 2) from ps where customer_id is null), 0),
      'avg_spend_per_customer', coalesce((select round(avg(net), 2) from per_customer), 0),
      'top_customers', coalesce((select jsonb_agg(x order by x.net desc) from (
          select c.id, c.name, c.phone, pc.invoices, pc.net, pc.last_at,
                 coalesce(a.loyalty_points, 0) as loyalty_points, coalesce(a.account_balance, 0) as account_balance
            from per_customer pc join public.customers c on c.id = pc.customer_id
            left join public.customer_accounts a on a.customer_id = c.id
           order by pc.net desc limit 10) x), '[]'::jsonb),
      'segments', coalesce((select jsonb_object_agg(segment, jsonb_build_object('count', cnt, 'value', val)) from (
          select segment, count(*) as cnt, coalesce(sum(m365), 0) as val from seg group by segment) x), '{}'::jsonb),
      'at_risk_customers', coalesce((select jsonb_agg(x order by x.value desc) from (
          select c.id, c.name, c.phone, sg.r as days_since, sg.f365 as invoices, coalesce(sg.m365, 0) as value
            from seg sg join public.customers c on c.id = sg.customer_id
           where sg.segment = 'at_risk' order by sg.m365 desc nulls last limit 10) x), '[]'::jsonb),
      'loyalty', jsonb_build_object(
        'enabled', s.loyalty_enabled,
        'points_outstanding', coalesce((select sum(loyalty_points) from public.customer_accounts where loyalty_points > 0), 0),
        'liability', round(coalesce((select sum(loyalty_points) from public.customer_accounts where loyalty_points > 0), 0)
                           * s.loyalty_point_value, 2),
        'earned', coalesce((select sum(points) from public.loyalty_ledger
                             where entry_type = 'earn' and created_at >= v_from and created_at < v_to), 0),
        'redeemed', coalesce((select -sum(points) from public.loyalty_ledger
                               where entry_type = 'redeem' and created_at >= v_from and created_at < v_to), 0),
        'redeemed_value', coalesce((select sum(loyalty_discount) from ps), 0)),
      'credit', jsonb_build_object(
        'receivable', coalesce((select sum(account_balance) from public.customer_accounts where account_balance > 0), 0),
        'credit_balances', coalesce((select -sum(account_balance) from public.customer_accounts where account_balance < 0), 0),
        'credit_sales', coalesce((select sum(p.amount) from public.sale_payments p join ps on ps.id = p.sale_id
                                   where p.method::text = 'on_account'), 0),
        'collections', coalesce((select sum(amount) from public.customer_payments
                                  where kind = 'receipt' and voided_at is null
                                    and created_at >= v_from and created_at < v_to), 0)),
      'promotions', coalesce((select jsonb_agg(x order by x.discount desc) from (
          select pr.id, pr.name, pr.code, count(distinct i.sale_id) as invoices, sum(i.qty) as units,
                 sum(i.promo_discount) as discount, sum(i.line_total) as revenue
            from public.sale_items i join ps on ps.id = i.sale_id
            join public.promotions pr on pr.id = i.promotion_id
           group by pr.id, pr.name, pr.code) x), '[]'::jsonb),
      'reservations', jsonb_build_object(
        'active', (select count(*) from public.reservations where status = 'active' and expires_at > now()),
        'expired', (select count(*) from public.reservations where status = 'active' and expires_at <= now()),
        'fulfilled', (select count(*) from public.reservations where status = 'fulfilled'
                        and closed_at >= v_from and closed_at < v_to),
        'cancelled', (select count(*) from public.reservations where status = 'cancelled'
                        and closed_at >= v_from and closed_at < v_to)),
      'whatsapp_sent', (select count(*) from public.message_log where created_at >= v_from and created_at < v_to)
    )
  );
end;
$$;

revoke execute on function public.customer_profile(uuid), public.customer_analytics(date, date) from public, anon;
grant execute on function public.customer_profile(uuid), public.customer_analytics(date, date) to authenticated;

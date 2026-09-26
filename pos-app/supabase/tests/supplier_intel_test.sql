-- اختبار 0020 (على قاعدة اختبار فقط): التكلفة الواصلة، مدة التوريد ونسبة التوريد الفعلية، تقييم المورد والأوزان،
-- «لماذا؟» بالأرقام، مورد بلا بيانات لا يُرشَّح، اقتراح على مستوى الموديل، تاريخ الأسعار وتنبيه الارتفاع،
-- مسودات حسب المورد (منع التكرار)، المتبقي من الاستلام الجزئي في مساعد الشراء، اللوحة، والصلاحيات
\set ON_ERROR_STOP 1
begin;

create function pg_temp.expect_error(p_sql text, p_like text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm not like p_like then
      raise exception 'unexpected error "%" (expected like "%") for: %', sqlerrm, p_like, p_sql;
    end if;
    return;
  end;
  raise exception 'expected error like "%" but succeeded: %', p_like, p_sql;
end $$;
create function pg_temp.as_user(p uuid) returns void language sql as $$ select set_config('request.jwt.claim.sub', p::text, true) $$;
create temp table t (k text primary key, id uuid);
grant all on t to authenticated;
create function pg_temp.id(p_k text) returns uuid language sql as $$ select id from t where k = p_k $$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000e1', 'owner@si.test');
insert into auth.users (id, email, raw_app_meta_data) values
  ('00000000-0000-0000-0000-0000000000e2', 'manager@si.test', '{"role":"manager"}'),
  ('00000000-0000-0000-0000-0000000000e3', 'cashier@si.test', '{"role":"cashier"}');
insert into public.suppliers (id, name, vat_registered) values
  ('00000000-0000-0000-0000-000000000ba1', 'مصنع أ', true),
  ('00000000-0000-0000-0000-000000000bb1', 'مصنع ب', true),
  ('00000000-0000-0000-0000-000000000bc1', 'مورد جديد', true),
  ('00000000-0000-0000-0000-000000000bd1', 'شركة الشحن', true);
insert into public.products (id, name, base_price) values
  ('00000000-0000-0000-0000-00000000e201', 'قميص', 120),
  ('00000000-0000-0000-0000-00000000e202', 'حزام', 50);
insert into public.product_variants (id, product_id, sku, size) values
  ('00000000-0000-0000-0000-00000000f201', '00000000-0000-0000-0000-00000000e201', 'SH-M', 'M'),
  ('00000000-0000-0000-0000-00000000f202', '00000000-0000-0000-0000-00000000e201', 'SH-L', 'L'),
  ('00000000-0000-0000-0000-00000000f203', '00000000-0000-0000-0000-00000000e202', 'BELT', null);

-- دورة شراء كاملة: أمر → اعتماد (بتاريخ سابق) → استلام → فاتورة
create function pg_temp.buy(p_k text, p_supplier uuid, p_variant uuid, p_qty int, p_cost numeric, p_days_ago int, p_receive int, p_inv_cost numeric)
returns void language plpgsql as $$
declare v_po uuid := gen_random_uuid(); v_grn uuid; v_inv uuid;
begin
  insert into public.purchase_orders (id, po_no, supplier_id, status) values (v_po, 'PO-' || p_k, p_supplier, 'draft');
  insert into public.purchase_items (purchase_id, variant_id, qty, unit_cost) values (v_po, p_variant, p_qty, p_cost);
  perform public.approve_purchase_order(v_po);
  update public.purchase_orders set approved_at = now() - make_interval(days => p_days_ago) where id = v_po;
  v_grn := public.receive_goods(v_po, jsonb_build_array(jsonb_build_object('variant_id', p_variant, 'qty', p_receive)));
  v_inv := public.save_supplier_invoice(null, p_supplier, v_po, 'F-' || p_k, current_date, null, 'credit',
             (select jsonb_agg(jsonb_build_object('receipt_item_id', id, 'qty', qty, 'unit_cost', p_inv_cost)) from public.goods_receipt_items where receipt_id = v_grn));
  perform public.post_supplier_invoice(v_inv, case when p_inv_cost <> p_cost then 'سعر جديد' end);
  insert into t values ('PO-' || p_k, v_po), ('GRN-' || p_k, v_grn), ('INV-' || p_k, v_inv);
end $$;

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e2');
-- أ: 10 × 40، وصلت بعد 5 أيام كاملة، + شحن 25 ← 42.50 واصلة للقطعة
select pg_temp.buy('A1', '00000000-0000-0000-0000-000000000ba1', '00000000-0000-0000-0000-00000000f201', 10, 40, 5, 10, 40);
select public.post_landed_cost(array[pg_temp.id('GRN-A1')], '[{"cost_type":"freight","amount":25,"supplier_id":"00000000-0000-0000-0000-000000000bd1"}]', 'value');
-- ب: 10 × 48، وصل 8 فقط بعد 4 أيام ← نسبة توريد 80%
select pg_temp.buy('B1', '00000000-0000-0000-0000-000000000bb1', '00000000-0000-0000-0000-00000000f201', 10, 48, 4, 8, 48);
-- مورد جديد: سعر متفق عليه أرخص (30) لكن بلا مشتريات سابقة
insert into public.supplier_items (supplier_id, variant_id, supplier_sku, agreed_cost) values
  ('00000000-0000-0000-0000-000000000bc1', '00000000-0000-0000-0000-00000000f201', 'NEW-M', 30);

-- ============ 1) التقييم و«لماذا؟» ============
do $$ declare a record; b record; c record; s record; begin
  select * into a from public.supplier_scores(array['00000000-0000-0000-0000-00000000f201'::uuid]) where supplier_id = '00000000-0000-0000-0000-000000000ba1';
  select * into b from public.supplier_scores(array['00000000-0000-0000-0000-00000000f201'::uuid]) where supplier_id = '00000000-0000-0000-0000-000000000bb1';
  select * into c from public.supplier_scores(array['00000000-0000-0000-0000-00000000f201'::uuid]) where supplier_id = '00000000-0000-0000-0000-000000000bc1';
  -- أ: 50×1 + 20×(4/5) + 15×1 + 15×1 = 96.0 | ب: 50×(42.5/48) + 20×1 + 15×0.8 + 15×1 = 44.27 + 47 = 91.3
  assert a.cost = 42.50 and a.lead_days = 5.0 and a.fill_rate = 1 and a.score = 96.0 and a.rank = 1, format('A %s', row_to_json(a));
  assert b.cost = 48.00 and b.lead_days = 4.0 and b.fill_rate = 0.8 and b.score = 91.3 and b.rank = 2, format('B %s', row_to_json(b));
  assert not c.sufficient and c.rank is null and c.score is null and c.cost_basis = 'agreed', 'new supplier: insufficient data, not ranked';
  select * into s from public.suggest_suppliers(array['00000000-0000-0000-0000-00000000f201'::uuid]);
  assert s.supplier_id = '00000000-0000-0000-0000-000000000ba1', 'A suggested';
  assert s.reason like '%«مصنع أ»: 42.50 ر.س للقطعة واصلة (متوسط 1 فاتورة خلال 180 يوماً)، يورّد خلال 5.0 يوم، ويسلّم 100% من المطلوب%'
     and s.reason like '%مقارنةً بـ«مصنع ب»: 48.00 ر.س (+12.9%) رغم أنه أسرع بـ1.0 يوم — التقييم 96.0 مقابل 91.3.%', s.reason;
  assert jsonb_array_length(s.alternatives) = 2, 'alternatives listed (incl. insufficient)';
  -- مقاس لم يُشترَ من قبل: يُقترح من أسعار نفس الموديل
  select * into s from public.suggest_suppliers(array['00000000-0000-0000-0000-00000000f202'::uuid]);
  assert s.supplier_id = '00000000-0000-0000-0000-000000000ba1' and s.reason like '%من أسعار نفس الموديل%', 'model-level suggestion';
  -- صنف بلا أي تاريخ شراء: لا اقتراح
  assert not exists (select 1 from public.suggest_suppliers(array['00000000-0000-0000-0000-00000000f203'::uuid])), 'no suggestion without data';
end $$;

-- الأوزان من الإعدادات: السعر 100% ← أ ما زال الأرخص؛ مدة التوريد 100% ← ب الأسرع يتقدم
reset role;
update public.store_settings set supplier_weight_price = 0, supplier_weight_lead = 100, supplier_weight_fill = 0, supplier_weight_quality = 0 where id = 1;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e2');
do $$ begin
  assert (select supplier_id from public.suggest_suppliers(array['00000000-0000-0000-0000-00000000f201'::uuid])) = '00000000-0000-0000-0000-000000000bb1', 'weights change the ranking';
end $$;
reset role;
select pg_temp.expect_error($q$update public.store_settings set supplier_weight_price = 60 where id = 1$q$, '%supplier_weights_sum%');
update public.store_settings set supplier_weight_price = 50, supplier_weight_lead = 20, supplier_weight_fill = 15, supplier_weight_quality = 15 where id = 1;

-- ============ 2) المتبقي من الاستلام الجزئي في مساعد الشراء ومركز القرارات ============
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e2');
do $$ begin
  assert (select on_order from public.purchase_advisor() where sku = 'SH-M') = 2, 'advisor counts remaining 2 of partially received PO';
  assert (select on_order from public.location_availability(null) where sku = 'SH-M') = 2, 'availability counts remaining 2';
end $$;

-- ============ 3) مسودات حسب المورد ============
select pg_temp.expect_error($q$select public.create_purchase_drafts_by_supplier(('[{"variant_id":"00000000-0000-0000-0000-00000000f203","location_id":"' || (select id from public.locations where code = 'MAIN') || '","qty":2}]')::jsonb)$q$,
  '%BELT%');
insert into t select 'PD', null;
create temp table pd as select public.create_purchase_drafts_by_supplier(jsonb_build_array(
  jsonb_build_object('variant_id', '00000000-0000-0000-0000-00000000f201', 'location_id', (select id from public.locations where code = 'MAIN'), 'qty', 5),
  jsonb_build_object('variant_id', '00000000-0000-0000-0000-00000000f202', 'location_id', (select id from public.locations where code = 'MAIN'), 'qty', 3),
  jsonb_build_object('variant_id', '00000000-0000-0000-0000-00000000f202', 'location_id', (select id from public.locations where code = 'MAIN'), 'qty', 4,
                     'supplier_id', '00000000-0000-0000-0000-000000000bb1')),
  null, 'ac000000-0000-0000-0000-000000000001') as res;
grant select on pd to authenticated;
do $$ declare v_again jsonb; begin
  -- أ (مقترح): SH-M 5 + SH-L 3 | ب (محدد): SH-L 4
  assert jsonb_array_length((select res from pd)) = 2, 'two drafts grouped by supplier';
  assert (select sum(pi.qty) from public.purchase_items pi join public.purchase_orders po on po.id = pi.purchase_id
           where po.supplier_id = '00000000-0000-0000-0000-000000000ba1' and po.status = 'draft') = 8, 'A draft 8 pcs';
  v_again := public.create_purchase_drafts_by_supplier(jsonb_build_array(
    jsonb_build_object('variant_id', '00000000-0000-0000-0000-00000000f201', 'location_id', (select id from public.locations where code = 'MAIN'), 'qty', 5)),
    null, 'ac000000-0000-0000-0000-000000000001');
  assert v_again -> 0 ->> 'id' = (select res -> 0 ->> 'id' from pd) or v_again -> 0 ->> 'id' = (select res -> 1 ->> 'id' from pd), 'same client ref → same draft';
  assert (select count(*) from public.purchase_orders where status = 'draft') = 2, 'no duplicate drafts';
  assert (select on_order from public.location_availability(null) where sku = 'SH-M') = 7, 'drafts counted as on order (2 + 5)';
end $$;

-- ============ 4) تاريخ الأسعار، التنبيه، المقارنة، واللوحة ============
select pg_temp.buy('A2', '00000000-0000-0000-0000-000000000ba1', '00000000-0000-0000-0000-00000000f201', 2, 40, 3, 2, 46);
-- ب: وصول القطعتين الباقيتين بلا فاتورة ← مستلم غير مفوتر 2 × 48 = 96
select public.receive_goods(pg_temp.id('PO-B1'));
do $$ declare h record; d jsonb; c record; begin
  select * into h from public.supplier_price_history('00000000-0000-0000-0000-00000000f201') where doc_no = (select doc_no from public.supplier_invoices where id = pg_temp.id('INV-A2'));
  -- 40 ← 46 = +15%
  assert h.change_pct = 15.0 and h.unit_cost = 46, format('price change %s', row_to_json(h));
  -- متوسط أ المرجّح: (42.50 × 10 + 46 × 2) ÷ 12 = 43.08
  assert (select cost from public.supplier_scores(array['00000000-0000-0000-0000-00000000f201'::uuid]) where supplier_id = '00000000-0000-0000-0000-000000000ba1') = 43.08, 'weighted landed cost';
  select * into c from public.supplier_price_comparison('00000000-0000-0000-0000-00000000e201') where sku = 'SH-M' and is_best;
  assert c.supplier_name = 'مصنع أ' and c.last_cost = 46, format('comparison %s', row_to_json(c));
  d := public.purchasing_dashboard();
  assert (d -> 'received_not_invoiced' ->> 'value')::numeric = 96 and (d -> 'received_not_invoiced' ->> 'lines')::int = 1, format('RNI %s', d -> 'received_not_invoiced');
  assert jsonb_array_length(d -> 'price_alerts') = 1 and d -> 'price_alerts' -> 0 ->> 'sku' = 'SH-M', 'price alert';
  -- الضريبة: 60 + 57.60 + 3.75 (شحن) + 13.80 = 135.15
  assert (d ->> 'input_vat_this_month')::numeric = 135.15, format('input VAT %s', d ->> 'input_vat_this_month');
  -- المفتوح: 460 + 441.60 + 28.75 + 105.80 = 1036.15، ولا متأخر
  assert (d -> 'overdue' ->> 'open')::numeric = 1036.15 and (d -> 'overdue' ->> 'total')::numeric = 0, format('open %s', d -> 'overdue');
  assert (d ->> 'draft_invoices')::int = 0 and jsonb_array_length(d -> 'top_creditors') = 3, 'dashboard lists creditors';
end $$;

-- ============ 5) الصلاحيات ============
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e3');
select pg_temp.expect_error($q$select * from public.suggest_suppliers(array[gen_random_uuid()])$q$, 'غير مصرح');
select pg_temp.expect_error($q$select public.purchasing_dashboard()$q$, 'غير مصرح');
select pg_temp.expect_error($q$select * from public.supplier_price_history()$q$, 'غير مصرح');
select pg_temp.expect_error($q$insert into public.supplier_items (supplier_id, variant_id) values ('00000000-0000-0000-0000-000000000ba1', '00000000-0000-0000-0000-00000000f203')$q$, '%row-level security%');
do $$ begin
  assert (select count(*) from public.supplier_items) = 0, 'cashier cannot read supplier catalog';
end $$;
reset role;
rollback;

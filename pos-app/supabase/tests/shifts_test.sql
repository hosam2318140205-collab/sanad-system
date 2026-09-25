-- اختبار الورديات وإغلاق الصندوق (على قاعدة اختبار فقط)
\set ON_ERROR_STOP 1
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000c001', 'owner@shift.test');
insert into auth.users (id, email, raw_app_meta_data) values
  ('00000000-0000-0000-0000-00000000c002', 'cashier@shift.test', '{"role":"cashier"}'),
  ('00000000-0000-0000-0000-00000000c003', 'cashier2@shift.test', '{"role":"cashier"}');
insert into public.products (id, name, base_price) values ('00000000-0000-0000-0000-00000000d001', 'قميص', 100);
insert into public.product_variants (id, product_id, sku, stock_qty) values
  ('00000000-0000-0000-0000-00000000e001', '00000000-0000-0000-0000-00000000d001', 'SH-TEST', 50);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000c002', true);

-- البيع ممنوع بدون وردية
do $$ begin
  begin
    perform public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-00000000e001","qty":1}]', '[{"method":"cash","amount":100}]');
    raise exception 'sale without shift allowed';
  exception when others then
    if sqlerrm = 'sale without shift allowed' then raise; end if;
    assert sqlerrm like '%افتح الوردية%', sqlerrm;
  end;
end $$;

create temp table t_shift as select public.open_shift(200, 'بداية الدوام') as id;
grant select on t_shift to authenticated;

-- وردية ثانية للموظف نفسه ممنوعة
do $$ begin
  begin
    perform public.open_shift(0);
    raise exception 'second open shift allowed';
  exception when others then
    if sqlerrm = 'second open shift allowed' then raise; end if;
  end;
end $$;

-- بيع نقدي 100 دفع 150 (باقي 50) + بيع شبكة 200 + بيع مقسم 60 نقد / 40 شبكة
create temp table t_s1 as select public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-00000000e001","qty":1}]', '[{"method":"cash","amount":150}]') as id;
select public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-00000000e001","qty":2}]', '[{"method":"card","amount":200}]');
select public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-00000000e001","qty":1}]', '[{"method":"cash","amount":60},{"method":"card","amount":40}]');

-- مرتجع نقدي للبيع الأول (100)
select public.process_return(
  (select id from t_s1),
  jsonb_build_array(jsonb_build_object('sale_item_id', (select id from public.sale_items where sale_id = (select id from t_s1)), 'qty', 1)),
  'cash', 'مقاس');

-- حركات الدرج
select public.add_cash_movement('out', 30, 'شراء أكياس');
select public.add_cash_movement('in', 10, 'فكة');
do $$ begin
  begin
    perform public.add_cash_movement('out', 5, '  ');
    raise exception 'movement without reason allowed';
  exception when others then
    if sqlerrm = 'movement without reason allowed' then raise; end if;
  end;
end $$;

-- أثناء الوردية: الكاشير لا يرى النقد المتوقع
do $$
declare s jsonb := public.shift_summary((select id from t_shift));
begin
  assert (s -> 'numbers') ? 'expected_cash' = false, 'cashier must not see expected cash while open';
  assert (s -> 'numbers' ->> 'sales_count')::int = 3, 'sales count visible';
end $$;
do $$ begin
  begin
    perform expected_cash from public.shifts limit 1;
    raise exception 'cashier read expected_cash column';
  exception when insufficient_privilege then null;
  end;
end $$;

-- كل العمليات مربوطة بالوردية
do $$ begin
  assert (select count(*) from public.sales where shift_id = (select id from t_shift)) = 3, 'sales attached';
  assert (select count(*) from public.returns where shift_id = (select id from t_shift)) = 1, 'return attached';
end $$;

-- كاشير آخر لا يرى هذه الوردية
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000c003', true);
do $$ begin
  assert (select count(*) from public.shifts) = 0, 'other cashier sees no shifts';
  assert jsonb_array_length(public.list_shifts()) = 0, 'list_shifts filtered';
  begin
    perform public.shift_summary((select id from t_shift));
    raise exception 'other cashier read summary';
  exception when others then
    if sqlerrm = 'other cashier read summary' then raise; end if;
  end;
  begin
    perform public.close_shift((select id from t_shift), 0);
    raise exception 'other cashier closed shift';
  exception when others then
    if sqlerrm = 'other cashier closed shift' then raise; end if;
  end;
end $$;

-- المالك يرى المتوقع لحظياً
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000c001', true);
do $$
declare n jsonb := public.shift_summary((select id from t_shift)) -> 'numbers';
begin
  -- 200 افتتاحي + (150-50 + 60) نقد مبيعات - 100 مرتجع نقدي - 30 سحب + 10 إيداع = 240
  assert (n ->> 'cash_sales')::numeric = 160, format('cash_sales %s', n ->> 'cash_sales');
  assert (n ->> 'card_sales')::numeric = 240, format('card_sales %s', n ->> 'card_sales');
  assert (n ->> 'cash_refunds')::numeric = 100, 'cash refunds';
  assert (n ->> 'expected_cash')::numeric = 240, format('expected %s', n ->> 'expected_cash');
  assert (n ->> 'total_sales')::numeric = 400, 'total sales';
end $$;

-- الكاشير يغلق بعدّ 235 → عجز 5
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000c002', true);
do $$
declare s jsonb := public.close_shift((select id from t_shift), 235, 'نهاية الدوام');
begin
  assert s ->> 'status' = 'closed', 'closed';
  assert (s ->> 'cash_difference')::numeric = -5, format('difference %s', s ->> 'cash_difference');
  assert (s -> 'numbers' ->> 'expected_cash')::numeric = 240, 'cashier sees expected after close';
  assert jsonb_array_length(s -> 'movements') = 2, 'movements listed';
end $$;

-- بعد الإغلاق: لا بيع ولا حركات ولا إغلاق ثانٍ
do $$ begin
  begin
    perform public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-00000000e001","qty":1}]', '[{"method":"cash","amount":100}]');
    raise exception 'sale after close allowed';
  exception when others then
    if sqlerrm = 'sale after close allowed' then raise; end if;
  end;
  begin
    perform public.add_cash_movement('in', 1, 'x');
    raise exception 'movement after close allowed';
  exception when others then
    if sqlerrm = 'movement after close allowed' then raise; end if;
  end;
  begin
    perform public.close_shift((select id from t_shift), 0);
    raise exception 'double close allowed';
  exception when others then
    if sqlerrm = 'double close allowed' then raise; end if;
  end;
end $$;

-- المدير يغلق وردية نسيها موظف
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000c003', true);
create temp table t_shift2 as select public.open_shift(50) as id;
grant select on t_shift2 to authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000c001', true);
do $$
declare s jsonb := public.close_shift((select id from t_shift2), 50);
begin
  assert (s ->> 'cash_difference')::numeric = 0, 'manager closed with zero difference';
  assert jsonb_array_length(public.list_shifts()) = 2, 'owner lists all shifts';
end $$;

-- إيقاف شرط الوردية يسمح بالبيع (سلوك ما قبل الميزة)
reset role;
update public.store_settings set require_shift = false;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000c002', true);
create temp table t_free as
  select public.complete_sale('[{"variant_id":"00000000-0000-0000-0000-00000000e001","qty":1}]', '[{"method":"cash","amount":100}]') as id;
grant select on t_free to authenticated;
do $$ begin
  assert (select id from t_free) is not null, 'sale allowed when shifts optional';
  assert (select shift_id from public.sales where id = (select id from t_free)) is null, 'no shift attached';
end $$;

-- مرتجع بالشبكة لا يحتاج وردية حتى مع تفعيل الشرط
reset role;
update public.store_settings set require_shift = true;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000c002', true);
do $$
declare v_sale uuid := (select id from t_free);
begin
  assert public.process_return(v_sale,
    jsonb_build_array(jsonb_build_object('sale_item_id', (select id from public.sale_items where sale_id = v_sale), 'qty', 1)),
    'card', null) is not null, 'card refund without shift allowed';
end $$;

-- ...لكن المرتجع النقدي بدون وردية ممنوع
do $$
declare v_sale uuid := (select id from public.sales where shift_id is not null and status = 'completed' limit 1);
begin
  begin
    perform public.process_return(v_sale,
      jsonb_build_array(jsonb_build_object('sale_item_id', (select id from public.sale_items where sale_id = v_sale), 'qty', 1)),
      'cash', null);
    raise exception 'cash refund without shift allowed';
  exception when others then
    if sqlerrm = 'cash refund without shift allowed' then raise; end if;
    assert sqlerrm like '%افتح الوردية%', sqlerrm;
  end;
end $$;

rollback;

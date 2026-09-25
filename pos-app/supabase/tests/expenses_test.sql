-- اختبار المصروفات وصافي الربح (على قاعدة اختبار فقط)
\set ON_ERROR_STOP 1
begin;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000f001', 'owner@exp.test');
insert into auth.users (id, email, raw_app_meta_data) values
  ('00000000-0000-0000-0000-00000000f002', 'cashier@exp.test', '{"role":"cashier"}');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000f001', true);

do $$ begin
  assert (select count(*) from public.expense_categories) = 10, 'default categories seeded';
end $$;

-- مصروف بتحويل: إيجار 5750 شامل ضريبة 750
insert into public.expenses (category_id, amount, vat_amount, payment_method, payee, reference)
values ((select id from public.expense_categories where name = 'إيجار'), 5750, 750, 'transfer', 'المالك العقاري', 'INV-77');

do $$ begin
  assert (select expense_no from public.expenses limit 1) like 'EXP-%', 'expense number generated';
  assert (select shift_movement_id from public.expenses limit 1) is null, 'transfer does not touch drawer';
end $$;

-- الضريبة لا تتجاوز المبلغ
do $$ begin
  begin
    insert into public.expenses (category_id, amount, vat_amount, payment_method)
    values ((select id from public.expense_categories where name = 'أخرى'), 10, 20, 'cash');
    raise exception 'vat > amount allowed';
  exception when others then
    if sqlerrm = 'vat > amount allowed' then raise; end if;
  end;
end $$;

-- الدفع من الدرج بدون وردية مرفوض
do $$ begin
  begin
    insert into public.expenses (category_id, amount, payment_method)
    values ((select id from public.expense_categories where name = 'أخرى'), 30, 'cash_drawer');
    raise exception 'drawer expense without shift allowed';
  exception when others then
    if sqlerrm = 'drawer expense without shift allowed' then raise; end if;
    assert sqlerrm like '%وردية مفتوحة%', sqlerrm;
  end;
end $$;

-- مع وردية: يُسجَّل سحب تلقائي ويؤثر على المتوقع
create temp table t_shift as select public.open_shift(500) as id;
grant select on t_shift to authenticated;
create temp table t_exp as
with ins as (
  insert into public.expenses (category_id, amount, payment_method, payee)
  values ((select id from public.expense_categories where name like 'مستلزمات%'), 40, 'cash_drawer', 'محل الأكياس')
  returning id
) select id from ins;
grant select on t_exp to authenticated;

do $$
declare m public.shift_cash_movements;
begin
  select * into m from public.shift_cash_movements
   where id = (select shift_movement_id from public.expenses where id = (select id from t_exp));
  assert m.type = 'out' and m.amount = 40, 'drawer movement created';
  assert m.reason like 'مصروف EXP-%محل الأكياس', m.reason;
  assert (public.shift_summary((select id from t_shift)) -> 'numbers' ->> 'expected_cash')::numeric = 460, 'expected cash reduced';
end $$;

-- لا يُعدَّل مبلغ مصروف الدرج، لكن تُعدَّل الملاحظات
do $$ begin
  begin
    update public.expenses set amount = 10 where id = (select id from t_exp);
    raise exception 'drawer amount edited';
  exception when others then
    if sqlerrm = 'drawer amount edited' then raise; end if;
  end;
  begin
    update public.expenses set payment_method = 'cash' where id = (select id from t_exp);
    raise exception 'drawer method edited';
  exception when others then
    if sqlerrm = 'drawer method edited' then raise; end if;
  end;
end $$;
update public.expenses set notes = 'فاتورة مرفقة' where id = (select id from t_exp);

-- حذفه والوردية مفتوحة يحذف حركة الدرج
create temp table t_exp2 as
with ins as (
  insert into public.expenses (category_id, amount, payment_method)
  values ((select id from public.expense_categories where name = 'أخرى'), 15, 'cash_drawer') returning id, shift_movement_id
) select * from ins;
grant select on t_exp2 to authenticated;
delete from public.expenses where id = (select id from t_exp2);
do $$ begin
  assert not exists (select 1 from public.shift_cash_movements where id = (select shift_movement_id from t_exp2)), 'movement removed with expense';
  assert (public.shift_summary((select id from t_shift)) -> 'numbers' ->> 'expected_cash')::numeric = 460, 'expected restored';
end $$;

-- بعد إغلاق الوردية لا يُحذف مصروف الدرج
select public.close_shift((select id from t_shift), 460);
do $$ begin
  begin
    delete from public.expenses where id = (select id from t_exp);
    raise exception 'deleted drawer expense of closed shift';
  exception when others then
    if sqlerrm = 'deleted drawer expense of closed shift' then raise; end if;
  end;
end $$;

-- الملخص: 5750 + 40 = 5790، ضريبة 750، صافي 5040
do $$
declare s jsonb := public.expenses_summary(current_date - 1, current_date + 1);
begin
  assert (s ->> 'total')::numeric = 5790, format('total %s', s ->> 'total');
  assert (s ->> 'vat')::numeric = 750, 'vat';
  assert (s ->> 'net')::numeric = 5040, 'net';
  assert (s ->> 'from_drawer')::numeric = 40, 'from drawer';
  assert jsonb_array_length(s -> 'by_category') = 2, 'by category';
end $$;

-- الكاشير: لا يرى ولا يضيف مصروفات ولا ملخصاً
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000f002', true);
do $$ begin
  assert (select count(*) from public.expenses) = 0, 'cashier sees no expenses';
  begin
    insert into public.expenses (category_id, amount, payment_method)
    values ((select id from public.expense_categories limit 1), 1, 'cash');
    raise exception 'cashier inserted expense';
  exception when others then
    if sqlerrm = 'cashier inserted expense' then raise; end if;
  end;
  begin
    perform public.expenses_summary(current_date, current_date);
    raise exception 'cashier read summary';
  exception when others then
    if sqlerrm = 'cashier read summary' then raise; end if;
  end;
end $$;

-- الزائر: لا شيء
reset role;
set local role anon;
do $$ begin
  begin
    perform 1 from public.expenses;
    raise exception 'anon read expenses';
  exception when insufficient_privilege then null;
  end;
end $$;

rollback;

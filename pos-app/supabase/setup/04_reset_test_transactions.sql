-- =====================================================================
-- ⚠️ تصفير عمليات التجربة قبل الافتتاح الفعلي — لا يمكن التراجع عنه
-- يحذف كل: الفواتير والمدفوعات والمرتجعات والورديات والمصروفات وأوامر الشراء والجرد وحركات المخزون،
-- ويعيد ترقيم الفواتير لتبدأ من 1 (INV-..000001).
-- يُبقي: المنتجات والمقاسات والأسعار والتكاليف والعملاء والموردين والمستخدمين والإعدادات
-- وسجل التدقيق. الكميات الحالية تُسجَّل كرصيد افتتاحي — يُنصح بعمل جرد بعدها.
--
-- للتنفيذ: أزل "--" من السطر التالي فقط ثم شغّل الملف.
-- select set_config('pos.confirm_reset', 'DELETE-ALL-TRANSACTIONS', false);
-- =====================================================================
do $$
begin
  if coalesce(current_setting('pos.confirm_reset', true), '') <> 'DELETE-ALL-TRANSACTIONS' then
    raise exception 'لم يتم التأكيد — أزل "--" من سطر set_config في أعلى الملف ثم أعد التشغيل';
  end if;

  -- مخزون المواقع (Smart Inventory 2.0): لا تصفير والبضاعة في الطريق
  if to_regclass('public.transfers') is not null and exists (
    select 1 from public.transfers where status in ('approved', 'in_transit', 'short_received')) then
    raise exception 'توجد تحويلات مفتوحة — أكملها أو ألغها قبل التصفير';
  end if;
  if to_regclass('public.transfers') is not null then
    delete from public.transfer_events;
    delete from public.transfer_items;
    delete from public.transfers;
    delete from public.inventory_ops;
    delete from public.stock_count_scans;
    alter sequence public.transfer_seq restart with 1;
  end if;

  delete from public.return_items;
  delete from public.sale_payments;
  delete from public.returns;
  delete from public.sale_items;
  delete from public.sales;
  delete from public.purchase_items;
  delete from public.purchase_orders;
  delete from public.stock_count_items;
  delete from public.stock_counts;
  delete from public.stock_movements;
  delete from public.expenses;
  delete from public.shift_cash_movements;
  delete from public.shifts;

  alter sequence public.invoice_seq restart with 1;
  alter sequence public.return_seq restart with 1;
  alter sequence public.purchase_seq restart with 1;
  alter sequence public.count_seq restart with 1;
  alter sequence public.shift_seq restart with 1;
  alter sequence public.expense_seq restart with 1;

  -- الرصيد الافتتاحي: الإجمالي في stock_movements، وتوزيعه الحالي على المواقع كما هو في location_movements
  perform set_config('app.skip_location', 'on', true);
  insert into public.stock_movements (variant_id, type, qty_change, balance_after, note)
  select id, 'opening', stock_qty, stock_qty, 'رصيد افتتاحي بعد تصفير التجربة'
    from public.product_variants where stock_qty <> 0;
  perform set_config('app.skip_location', '', true);
  if to_regclass('public.location_movements') is not null then
    insert into public.location_movements (location_id, variant_id, type, qty_change, balance_after, note)
    select location_id, variant_id, 'opening', qty, qty, 'رصيد افتتاحي بعد تصفير التجربة'
      from public.location_stock where qty <> 0;
  end if;

  perform set_config('pos.confirm_reset', '', false);
  raise notice 'تم تصفير عمليات التجربة';
end $$;

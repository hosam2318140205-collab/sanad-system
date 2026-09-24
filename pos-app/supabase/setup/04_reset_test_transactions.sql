-- =====================================================================
-- ⚠️ تصفير عمليات التجربة قبل الافتتاح الفعلي — لا يمكن التراجع عنه
-- يحذف كل: الفواتير والمدفوعات والمرتجعات وأوامر الشراء والجرد وحركات المخزون،
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

  alter sequence public.invoice_seq restart with 1;
  alter sequence public.return_seq restart with 1;
  alter sequence public.purchase_seq restart with 1;
  alter sequence public.count_seq restart with 1;

  insert into public.stock_movements (variant_id, type, qty_change, balance_after, note)
  select id, 'opening', stock_qty, stock_qty, 'رصيد افتتاحي بعد تصفير التجربة'
    from public.product_variants where stock_qty <> 0;

  perform set_config('pos.confirm_reset', '', false);
  raise notice 'تم تصفير عمليات التجربة';
end $$;

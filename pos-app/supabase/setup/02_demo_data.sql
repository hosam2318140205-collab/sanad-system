-- =====================================================================
-- بيانات تجريبية بسيطة (اختيارية) — لتجربة البيع والباركود والطباعة قبل إدخال بضاعتك
-- كل ما هنا معلَّم ويُحذف بالكامل بملف 03_remove_demo_data.sql:
--   • رموز الأصناف تبدأ بـ DEMO-      • الباركود يبدأ بـ 299
--   • التصنيفات والعميل تنتهي بـ (تجريبي)
-- آمن للتكرار: لا يضيف شيئاً إن كانت البيانات التجريبية موجودة.
-- =====================================================================
do $$
declare
  v_cat_thobe uuid;
  v_cat_shirt uuid;
  v_cat_shmagh uuid;
  v_pid uuid;
begin
  if exists (select 1 from public.product_variants where sku like 'DEMO-%') then
    raise notice 'البيانات التجريبية موجودة مسبقاً — لم يُضف شيء';
    return;
  end if;

  insert into public.categories (name, sort_order) values ('ثياب (تجريبي)', 90) returning id into v_cat_thobe;
  insert into public.categories (name, sort_order) values ('تيشيرتات (تجريبي)', 91) returning id into v_cat_shirt;
  insert into public.categories (name, sort_order) values ('شمغ (تجريبي)', 92) returning id into v_cat_shmagh;

  -- ثوب: 3 مقاسات × لون واحد
  insert into public.products (name, name_en, category_id, base_price, description)
  values ('ثوب قطن تجريبي', 'Demo Thobe', v_cat_thobe, 149, 'بيانات تجريبية — يمكن حذفها')
  returning id into v_pid;
  insert into public.product_variants (product_id, sku, barcode, size, color, color_hex, stock_qty) values
    (v_pid, 'DEMO-THOB-54-W', '2990000000019', '54', 'أبيض', '#ffffff', 5),
    (v_pid, 'DEMO-THOB-56-W', '2990000000026', '56', 'أبيض', '#ffffff', 5),
    (v_pid, 'DEMO-THOB-58-W', '2990000000033', '58', 'أبيض', '#ffffff', 5);
  update public.variant_costs set cost_price = 70
   where variant_id in (select id from public.product_variants where product_id = v_pid);

  -- تيشيرت: 3 مقاسات × لونين
  insert into public.products (name, name_en, category_id, base_price, description)
  values ('تيشيرت بولو تجريبي', 'Demo Polo', v_cat_shirt, 79, 'بيانات تجريبية — يمكن حذفها')
  returning id into v_pid;
  insert into public.product_variants (product_id, sku, barcode, size, color, color_hex, stock_qty) values
    (v_pid, 'DEMO-POLO-S-K', '2990000000040', 'S', 'أسود', '#111111', 4),
    (v_pid, 'DEMO-POLO-M-K', '2990000000057', 'M', 'أسود', '#111111', 4),
    (v_pid, 'DEMO-POLO-L-K', '2990000000064', 'L', 'أسود', '#111111', 2),
    (v_pid, 'DEMO-POLO-S-N', '2990000000071', 'S', 'كحلي', '#1e2a4a', 4),
    (v_pid, 'DEMO-POLO-M-N', '2990000000088', 'M', 'كحلي', '#1e2a4a', 4),
    (v_pid, 'DEMO-POLO-L-N', '2990000000095', 'L', 'كحلي', '#1e2a4a', 2);
  update public.variant_costs set cost_price = 30
   where variant_id in (select id from public.product_variants where product_id = v_pid);

  -- شماغ: مقاس واحد
  insert into public.products (name, name_en, category_id, base_price, description)
  values ('شماغ تجريبي', 'Demo Shemagh', v_cat_shmagh, 95, 'بيانات تجريبية — يمكن حذفها')
  returning id into v_pid;
  insert into public.product_variants (product_id, sku, barcode, size, color, color_hex, stock_qty) values
    (v_pid, 'DEMO-SHMG-RED', '2990000000101', 'فري سايز', 'أحمر', '#c0392b', 10);
  update public.variant_costs set cost_price = 45
   where variant_id in (select id from public.product_variants where product_id = v_pid);

  insert into public.customers (name, phone, notes)
  values ('عميل (تجريبي)', '0500000001', 'DEMO');

  raise notice 'تمت إضافة البيانات التجريبية: 3 منتجات، 10 أصناف، عميل واحد';
end $$;

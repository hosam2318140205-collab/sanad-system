-- بيانات تجريبية اختيارية لمحل ملابس (للتجربة فقط — لا تُنفذ على بيانات حقيقية)
insert into public.categories (name, sort_order) values
  ('ثياب رجالية', 1), ('شمغ وغتر', 2), ('عبايات', 3), ('قمصان وتيشيرتات', 4), ('بناطيل', 5)
on conflict (name) do nothing;

do $$
declare
  v_pid uuid;
  v_cat uuid;
  s text;
  c record;
  n int := 0;
begin
  -- ثوب: مقاسات × لونين
  select id into v_cat from public.categories where name = 'ثياب رجالية';
  insert into public.products (name, name_en, category_id, brand, base_price)
  values ('ثوب قطن كلاسيك', 'Classic Thobe', v_cat, 'الأصيل', 149) returning id into v_pid;
  for c in select * from (values ('أبيض', '#ffffff', 'W'), ('بيج', '#d9c7a7', 'B')) as t(name, hex, code) loop
    foreach s in array array['52', '54', '56', '58', '60'] loop
      n := n + 1;
      insert into public.product_variants (product_id, sku, barcode, size, color, color_hex, stock_qty)
      values (v_pid, 'THOB-' || s || '-' || c.code, '62800000' || lpad(n::text, 5, '0'), s, c.name, c.hex, 8);
    end loop;
  end loop;
  update public.variant_costs set cost_price = 70 where variant_id in (select id from public.product_variants where product_id = v_pid);

  -- شماغ: مقاس واحد
  select id into v_cat from public.categories where name = 'شمغ وغتر';
  insert into public.products (name, name_en, category_id, brand, base_price)
  values ('شماغ أحمر فاخر', 'Red Shemagh', v_cat, 'البسام', 95) returning id into v_pid;
  insert into public.product_variants (product_id, sku, barcode, size, color, color_hex, stock_qty)
  values (v_pid, 'SHMG-RED', '6280000000901', 'فري سايز', 'أحمر', '#c0392b', 20);
  update public.variant_costs set cost_price = 45 where variant_id in (select id from public.product_variants where product_id = v_pid);

  -- تيشيرت: حروف × 3 ألوان
  select id into v_cat from public.categories where name = 'قمصان وتيشيرتات';
  insert into public.products (name, name_en, category_id, base_price)
  values ('تيشيرت قطن بولو', 'Polo Tee', v_cat, 79) returning id into v_pid;
  for c in select * from (values ('أسود', '#111111', 'K'), ('كحلي', '#1e2a4a', 'N'), ('أبيض', '#ffffff', 'W')) as t(name, hex, code) loop
    foreach s in array array['S', 'M', 'L', 'XL'] loop
      n := n + 1;
      insert into public.product_variants (product_id, sku, barcode, size, color, color_hex, stock_qty, low_stock_threshold)
      values (v_pid, 'POLO-' || s || '-' || c.code, '62800000' || lpad(n::text, 5, '0'), s, c.name, c.hex, case when s = 'XL' then 2 else 10 end, 3);
    end loop;
  end loop;
  update public.variant_costs set cost_price = 30 where variant_id in (select id from public.product_variants where product_id = v_pid);
end $$;

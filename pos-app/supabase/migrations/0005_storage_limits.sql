-- =====================================================================
-- حدود رفع صور المنتجات: 5MB كحد أقصى، صور فقط، وداخل مجلد products/
-- =====================================================================
update storage.buckets
   set file_size_limit = 5242880,
       allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']
 where id = 'product-images';

drop policy if exists "product images insert" on storage.objects;
drop policy if exists "product images update" on storage.objects;
drop policy if exists "product images delete" on storage.objects;

create policy "product images insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'product-images' and (storage.foldername(name))[1] = 'products' and public.is_manager());
create policy "product images update" on storage.objects for update to authenticated
  using (bucket_id = 'product-images' and (storage.foldername(name))[1] = 'products' and public.is_manager());
create policy "product images delete" on storage.objects for delete to authenticated
  using (bucket_id = 'product-images' and (storage.foldername(name))[1] = 'products' and public.is_manager());

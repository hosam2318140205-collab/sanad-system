-- =====================================================================
-- المصروفات وصافي الربح
--   • مصروفات مصنّفة بمبلغ شامل الضريبة + ضريبة مدخلات (إن وُجدت فاتورة ضريبية)
--   • الدفع من درج الوردية يُسجَّل تلقائياً كسحب في الوردية المفتوحة
--   • صورة الإيصال في مخزن خاص (غير عام) للمدير والمالك فقط
-- إضافة فقط: لا تغيير على الجداول والدوال السابقة
-- =====================================================================

create type public.expense_payment as enum ('cash_drawer', 'cash', 'card', 'transfer');

create table public.expense_categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (length(trim(name)) > 0),
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);

insert into public.expense_categories (name, sort_order) values
  ('إيجار', 1), ('رواتب', 2), ('كهرباء وماء', 3), ('اتصالات وإنترنت', 4), ('صيانة', 5),
  ('تسويق وإعلانات', 6), ('نقل وتوصيل', 7), ('مستلزمات المحل (أكياس، علاقات)', 8),
  ('رسوم حكومية', 9), ('أخرى', 10);

create sequence public.expense_seq start 1;

create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  expense_no text not null unique
    default ('EXP-' || to_char(now() at time zone 'Asia/Riyadh', 'YY') || lpad(nextval('public.expense_seq')::text, 5, '0')),
  category_id uuid not null references public.expense_categories (id),
  expense_date date not null default (now() at time zone 'Asia/Riyadh')::date,
  amount numeric(12,2) not null check (amount > 0),               -- المدفوع شامل الضريبة
  vat_amount numeric(12,2) not null default 0 check (vat_amount >= 0),
  payment_method public.expense_payment not null,
  payee text,
  reference text,                                                   -- رقم فاتورة المورد
  notes text,
  receipt_path text,                                                -- داخل مخزن expense-receipts
  shift_movement_id uuid references public.shift_cash_movements (id),
  created_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint vat_le_amount check (vat_amount <= amount)
);
create index expenses_date_idx on public.expenses (expense_date desc);
create index expenses_category_idx on public.expenses (category_id);

create trigger expenses_touch before update on public.expenses
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------
-- الدفع من الدرج: سحب تلقائي من الوردية المفتوحة للمستخدم
-- ---------------------------------------------------------------------
create or replace function public.expense_drawer_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_shift uuid;
  v_shift_status public.shift_status;
  v_category text;
begin
  if tg_op = 'INSERT' then
    if new.payment_method = 'cash_drawer' then
      select id into v_shift from public.shifts where cashier_id = auth.uid() and status = 'open';
      if v_shift is null then
        raise exception 'لا توجد لديك وردية مفتوحة للدفع من الدرج — افتح وردية أو اختر طريقة دفع أخرى';
      end if;
      select name into v_category from public.expense_categories where id = new.category_id;
      insert into public.shift_cash_movements (shift_id, type, amount, reason)
      values (v_shift, 'out', new.amount,
              'مصروف ' || new.expense_no || ': ' || coalesce(v_category, '') || coalesce(' — ' || nullif(trim(new.payee), ''), ''))
      returning id into new.shift_movement_id;
    else
      new.shift_movement_id := null;
    end if;
    return new;
  end if;

  if tg_op = 'UPDATE' then
    -- لا يُسمح بتغيير ارتباط الدرج أو المبلغ لمصروف مدفوع من الدرج (تقرير الوردية يعتمد عليه)
    if (old.payment_method = 'cash_drawer' or new.payment_method = 'cash_drawer')
       and (new.payment_method is distinct from old.payment_method or new.amount is distinct from old.amount) then
      raise exception 'لا يمكن تعديل مبلغ أو طريقة دفع مصروف مدفوع من الدرج — احذفه وأعد إدخاله';
    end if;
    new.shift_movement_id := old.shift_movement_id;
    new.expense_no := old.expense_no;
    new.created_by := old.created_by;
    return new;
  end if;

  -- DELETE
  if old.shift_movement_id is not null then
    select s.status into v_shift_status
      from public.shift_cash_movements m join public.shifts s on s.id = m.shift_id
     where m.id = old.shift_movement_id;
    if v_shift_status = 'closed' then
      raise exception 'لا يمكن حذف مصروف مدفوع من درج وردية مغلقة';
    end if;
  end if;
  return old;
end;
$$;

create trigger expenses_drawer_before before insert or update or delete on public.expenses
  for each row execute function public.expense_drawer_guard();

-- بعد حذف المصروف: حذف حركة الدرج المرتبطة (الوردية ما زالت مفتوحة — تحقق منه قبل الحذف)
create or replace function public.expense_drawer_cleanup()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.shift_movement_id is not null then
    delete from public.shift_cash_movements where id = old.shift_movement_id;
  end if;
  return old;
end;
$$;

create trigger expenses_drawer_after_delete after delete on public.expenses
  for each row execute function public.expense_drawer_cleanup();

-- ---------------------------------------------------------------------
-- RLS: المدير والمالك فقط
-- ---------------------------------------------------------------------
alter table public.expense_categories enable row level security;
alter table public.expenses enable row level security;

revoke all on public.expense_categories, public.expenses from anon;
grant select, insert, update, delete on public.expense_categories, public.expenses to authenticated;
revoke usage on sequence public.expense_seq from anon;
grant usage on sequence public.expense_seq to authenticated;

create policy expense_categories_all on public.expense_categories for all to authenticated
  using (public.is_manager()) with check (public.is_manager());
create policy expenses_all on public.expenses for all to authenticated
  using (public.is_manager()) with check (public.is_manager());

create trigger expense_categories_audit after insert or update or delete on public.expense_categories
  for each row execute function public.audit_trigger();
create trigger expenses_audit after insert or update or delete on public.expenses
  for each row execute function public.audit_trigger();

-- ---------------------------------------------------------------------
-- ملخص المصروفات لفترة (للتقارير ولوحة التحكم)
-- ---------------------------------------------------------------------
create or replace function public.expenses_summary(p_from date, p_to date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_manager() then
    raise exception 'غير مصرح';
  end if;
  return (
    with e as (
      select * from public.expenses where expense_date between p_from and p_to
    )
    select jsonb_build_object(
      'total', coalesce((select sum(amount) from e), 0),
      'vat', coalesce((select sum(vat_amount) from e), 0),
      'net', coalesce((select sum(amount - vat_amount) from e), 0),
      'count', (select count(*) from e),
      'from_drawer', coalesce((select sum(amount) from e where payment_method = 'cash_drawer'), 0),
      'by_category', coalesce((
        select jsonb_agg(t order by t.total desc) from (
          select c.name, sum(e.amount) as total, sum(e.amount - e.vat_amount) as net, count(*) as count
            from e join public.expense_categories c on c.id = e.category_id
           group by c.name
        ) t), '[]'::jsonb)
    )
  );
end;
$$;

revoke execute on function public.expenses_summary(date, date) from public, anon;
revoke execute on function public.expense_drawer_guard(), public.expense_drawer_cleanup() from public, anon;
grant execute on function public.expenses_summary(date, date) to authenticated;

-- ---------------------------------------------------------------------
-- صور الإيصالات: مخزن خاص (روابط موقّعة مؤقتة)، للمدير والمالك فقط، داخل مجلد expenses/
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('expense-receipts', 'expense-receipts', false, 5242880,
        array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do nothing;

create policy "expense receipts read" on storage.objects for select to authenticated
  using (bucket_id = 'expense-receipts' and (storage.foldername(name))[1] = 'expenses' and public.is_manager());
create policy "expense receipts insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'expense-receipts' and (storage.foldername(name))[1] = 'expenses' and public.is_manager());
create policy "expense receipts update" on storage.objects for update to authenticated
  using (bucket_id = 'expense-receipts' and (storage.foldername(name))[1] = 'expenses' and public.is_manager());
create policy "expense receipts delete" on storage.objects for delete to authenticated
  using (bucket_id = 'expense-receipts' and (storage.foldername(name))[1] = 'expenses' and public.is_manager());

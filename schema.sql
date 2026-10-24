-- KABAURIA Affiliate Portal — skema Supabase (mulai dari nol, tanpa data demo)
-- Jalankan sekali di Supabase Dashboard > SQL Editor.

-- ========== ADMIN ==========
create table public.admins (user_id uuid primary key references auth.users(id) on delete cascade);
create function public.is_admin() returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.admins where user_id = auth.uid()) $$;

-- ========== TABEL ==========
create table public.settings    (key text primary key, data jsonb not null default '{}', updated_at timestamptz not null default now());
create table public.products    (id text primary key, data jsonb not null, created_at timestamptz not null default now());
create table public.affiliates  (id text primary key, data jsonb not null, created_at timestamptz not null default now());
create table public.orders      (id text primary key, affiliate_id text, data jsonb not null, created_at timestamptz not null default now());
create table public.commissions (id text primary key, affiliate_id text, data jsonb not null, created_at timestamptz not null default now());
create table public.payouts     (id text primary key, affiliate_id text, data jsonb not null, created_at timestamptz not null default now());
create table public.audit       (id text primary key, data jsonb not null, created_at timestamptz not null default now());
create index on public.orders(affiliate_id);
create index on public.commissions(affiliate_id);
create index on public.payouts(affiliate_id);
create index affiliates_code_idx on public.affiliates (lower(data->>'code'));

-- Katalog publik: tanpa aturan komisi produk
create view public.products_public as
  select id, created_at, data - 'commissionMode' - 'commissionValue' as data from public.products;
grant select on public.products_public to anon, authenticated;

-- ========== RLS ==========
alter table public.admins      enable row level security;
alter table public.settings    enable row level security;
alter table public.products    enable row level security;
alter table public.affiliates  enable row level security;
alter table public.orders      enable row level security;
alter table public.commissions enable row level security;
alter table public.payouts     enable row level security;
alter table public.audit       enable row level security;

create policy settings_read  on public.settings for select using (key = 'payments' or auth.uid() is not null);
create policy settings_admin on public.settings for all using (public.is_admin()) with check (public.is_admin());
create policy products_admin on public.products for all using (public.is_admin()) with check (public.is_admin());
create policy aff_read       on public.affiliates  for select using (public.is_admin() or id = auth.uid()::text);
create policy aff_admin      on public.affiliates  for all using (public.is_admin()) with check (public.is_admin());
create policy orders_read    on public.orders      for select using (public.is_admin() or affiliate_id = auth.uid()::text);
create policy orders_admin   on public.orders      for all using (public.is_admin()) with check (public.is_admin());
create policy comm_read      on public.commissions for select using (public.is_admin() or affiliate_id = auth.uid()::text);
create policy comm_admin     on public.commissions for all using (public.is_admin()) with check (public.is_admin());
create policy payouts_read   on public.payouts     for select using (public.is_admin() or affiliate_id = auth.uid()::text);
create policy payouts_admin  on public.payouts     for all using (public.is_admin()) with check (public.is_admin());
create policy audit_admin    on public.audit       for all using (public.is_admin()) with check (public.is_admin());

-- ========== STORAGE (foto produk & QRIS) ==========
insert into storage.buckets (id, name, public) values ('kabauria', 'kabauria', true) on conflict (id) do nothing;
create policy kabauria_insert on storage.objects for insert with check (bucket_id = 'kabauria' and public.is_admin());
create policy kabauria_delete on storage.objects for delete using (bucket_id = 'kabauria' and public.is_admin());

-- ========== FUNGSI ==========
create function public._log(a text, d text) returns void language plpgsql security definer set search_path=public as $$
declare i text := 'log_' || replace(gen_random_uuid()::text,'-','');
begin
  insert into public.audit(id, data) values (i, jsonb_build_object('id', i,
    'date', to_char(now() at time zone 'utc','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'), 'action', a, 'detail', d));
end $$;
revoke all on function public._log(text, text) from public, anon, authenticated;

create function public._aff_ok(d jsonb) returns boolean language sql stable
as $$ select d->>'status' = 'active' and d->>'deletedAt' is null
       and (coalesce(d->>'endDate','') = '' or d->>'endDate' >= to_char(current_date,'YYYY-MM-DD')) $$;

-- Cari affiliate aktif dari kode referral (untuk pengunjung anonim)
create function public.resolve_referral(p_code text) returns text language sql stable security definer set search_path=public
as $$ select id from public.affiliates where lower(data->>'code') = lower(p_code) and public._aff_ok(data) limit 1 $$;

-- Pelanggan membuat pesanan (harga & atribusi dihitung di server)
create function public.place_order(p_product text, p_items jsonb, p_customer text, p_phone text, p_address text,
  p_note text, p_method text, p_source text, p_ref text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare pr jsonb; v jsonb; it jsonb; items jsonb := '[]'; qty int := 0; price numeric; aff text; o jsonb; no text; lbl text; ix int;
begin
  select data into pr from products where id = p_product;
  if pr is null then raise exception 'Produk tidak ditemukan'; end if;
  if coalesce(trim(p_customer),'')='' or coalesce(trim(p_phone),'')='' or coalesce(trim(p_address),'')='' then
    raise exception 'Data pelanggan belum lengkap'; end if;
  if p_method not in ('qris','transfer','cash') then raise exception 'Metode pembayaran tidak valid'; end if;
  price := (pr->>'price')::numeric;
  for it in select * from jsonb_array_elements(p_items) loop
    ix := (it->>'variantIndex')::int;
    if ix < 0 or (it->>'qty')::int <= 0 then raise exception 'Variasi tidak valid'; end if;
    v := pr->'variants'->ix;
    if v is null then raise exception 'Variasi tidak valid'; end if;
    if (v->>'stock')::int < (it->>'qty')::int then raise exception 'Stok tidak mencukupi'; end if;
    lbl := array_to_string(array(select x from unnest(array[v->>'group',v->>'type',v->>'color',v->>'size']) x where coalesce(x,'')<>''), ' / ');
    items := items || jsonb_build_object('variantIndex', ix, 'label', lbl, 'qty', (it->>'qty')::int);
    qty := qty + (it->>'qty')::int;
  end loop;
  if qty = 0 then raise exception 'Pilih minimal 1 variasi'; end if;
  if p_source is distinct from 'admin' and p_ref is not null then
    select id into aff from affiliates where id = p_ref and _aff_ok(data);
  end if;
  loop
    no := 'KBR-' || (floor(random()*900000) + 100000)::int;
    exit when not exists (select 1 from orders where data->>'orderNo' = no);
  end loop;
  o := jsonb_build_object('id','ord_'||replace(gen_random_uuid()::text,'-',''),'orderNo',no,'productId',p_product,
    'productName',pr->>'name','variantIndex',(items->0->>'variantIndex')::int,
    'variantLabel',(select string_agg(i->>'label',' + ') from jsonb_array_elements(items) i),
    'items',items,'qty',qty,'unitPrice',price,'total',price*qty,
    'customerName',trim(p_customer),'phone',trim(p_phone),'address',trim(p_address),'note',trim(coalesce(p_note,'')),
    'affiliateId',aff,'affiliateCode',(select data->>'code' from affiliates where id = aff),
    'paymentMethod',p_method,
    'source',case when p_source = 'admin' then 'admin' when aff is not null then 'affiliate' else 'direct' end,
    'status','awaiting_payment','createdAt',to_char(now() at time zone 'utc','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'paymentConfirmedAt',null,'stockDeducted',false,'commissionId',null,'thumbUrl',coalesce(pr->>'imageUrl',''));
  insert into orders(id, affiliate_id, data) values (o->>'id', aff, o);
  perform _log('Pesanan dibuat', no || ' · ' || (pr->>'name'));
  return o;
end $$;
grant execute on function public.resolve_referral(text) to anon, authenticated;
grant execute on function public.place_order(text,jsonb,text,text,text,text,text,text,text) to anon, authenticated;

-- Affiliate menandai pelanggan sudah membayar (admin tetap yang memverifikasi)
create function public.claim_payment(p_id text) returns void language plpgsql security definer set search_path=public as $$
declare o orders; nm text;
begin
  select * into o from orders where id = p_id and affiliate_id = auth.uid()::text and data->>'status' = 'awaiting_payment' for update;
  if not found then raise exception 'Pesanan tidak ditemukan atau sudah diproses'; end if;
  select data->>'name' into nm from affiliates where id = auth.uid()::text;
  update orders set data = data || jsonb_build_object('status','payment_claimed','claimedBy',auth.uid()::text,
    'claimedByName',nm,'claimedAt',to_char(now() at time zone 'utc','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')) where id = p_id;
  perform _log('Affiliate konfirmasi bayar', (o.data->>'orderNo') || ' oleh ' || nm || ' · menunggu verifikasi admin');
end $$;
grant execute on function public.claim_payment(text) to authenticated;

-- ========== PENGATURAN AWAL ==========
insert into public.settings(key, data) values
 ('payments', '{"qris":{"enabled":false,"image":""},"transfer":{"enabled":false,"bank":"","number":"","holder":""},"cash":{"enabled":true,"note":"Bayar tunai langsung kepada admin atau affiliate yang melayani Anda."}}'),
 ('program',  '{"commissionMode":"fixed","commissionValue":10000,"defaultExpiryMonths":6}')
on conflict (key) do nothing;

-- ========== ADMIN PERTAMA ==========
-- 1) Authentication > Users > Add user (email + password, centang Auto Confirm)
-- 2) Jalankan (ganti emailnya):
-- insert into public.admins(user_id) select id from auth.users where email = 'admin@emailanda.com';

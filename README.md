# KABAURIA Affiliate Portal

Portal katalog, referral, pesanan, dan komisi affiliate. Frontend statis (`index.html`) + Supabase (database, Auth, Storage). Mulai dari nol: tanpa data demo, tidak membaca localStorage lama.

## Struktur
- `index.html` — aplikasi (satu file)
- `config.js` — URL & anon key Supabase
- `supabase/schema.sql` — tabel, RLS, fungsi, storage bucket

## Setup Supabase
1. Buat project di supabase.com.
2. **Authentication → Providers → Email**: matikan **Confirm email** (wajib, agar admin bisa membuat akun affiliate dari dashboard).
3. **SQL Editor**: tempel isi `supabase/schema.sql` → Run.
4. **Authentication → Users → Add user** (email + password, centang Auto Confirm) untuk akun admin.
5. Jadikan admin (ganti email):
   ```sql
   insert into public.admins(user_id) select id from auth.users where email = 'admin@emailanda.com';
   ```
6. **Project Settings → API**: salin *Project URL* dan *anon public key* ke `config.js`.

## Deploy ke GitHub Pages
```bash
git init && git add . && git commit -m "KABAURIA affiliate portal"
git branch -M main
git remote add origin https://github.com/USERNAME/REPO.git
git push -u origin main
```
Repo → **Settings → Pages** → Source: *Deploy from a branch* → `main` / `(root)`.
Link referral: `https://USERNAME.github.io/REPO/?ref=KODE` · link penjualan admin: `...?sales=admin`.

## Catatan
- Login admin & affiliate memakai **email + password** (Supabase Auth). Password affiliate ditetapkan saat akun dibuat; ganti password lewat Supabase Dashboard.
- Anon key aman dipublikasikan; akses data dibatasi RLS. **Jangan** pernah memasukkan `service_role` key ke repo.
- Komisi default awal Rp10.000/pcs — ubah di Dashboard admin → Pengaturan.
- Foto produk/QRIS diunggah ke Storage bucket `kabauria` (bukan lagi base64).

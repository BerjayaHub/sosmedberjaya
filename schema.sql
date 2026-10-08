-- ============================================================
-- Content Hub - skema Supabase (project baru)
-- Cara pakai: Supabase > SQL Editor > New query > tempel semua > Run.
-- Hasil terakhir menampilkan dua token rahasia (admin dan owner).
-- Aman dijalankan ulang: tabel dan token yang sudah ada tidak ditimpa.
-- ============================================================

-- ---------- Tabel ----------
create table if not exists public.content_items (
  id             uuid primary key default gen_random_uuid(),
  outlet         text not null,
  planned_date   date,
  platform       text not null default 'Instagram + TikTok',
  kind           text not null default 'AMAN' check (kind in ('AMAN','SENSITIF')),
  title          text not null,
  caption        text not null default '',
  hashtags       text not null default '',
  raw_url        text not null default '',   -- link folder/video mentah di Google Drive
  edit_url       text not null default '',   -- link video hasil edit di Google Drive
  pic            text not null default '',
  status         text not null default 'Ide' check (status in
                   ('Ide','Menunggu Bahan','Bahan Masuk','Diedit','Menunggu Approval',
                    'Disetujui','Terjadwal','Sudah Tayang','Ditolak')),
  submitted_at   timestamptz,
  decided_at     timestamptz,
  auto_approved  boolean not null default false,
  owner_note     text not null default '',
  posted_url     text not null default '',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create table if not exists public.content_outlets (
  name text primary key,
  sort int not null default 0
);

create table if not exists public.content_settings (
  key   text primary key,
  value text not null
);

create table if not exists public.access_links (
  role  text primary key check (role in ('admin','owner')),
  token text not null unique
);

-- Semua akses lewat fungsi cs_* di bawah. Tabel tertutup untuk akses langsung.
alter table public.content_items    enable row level security;
alter table public.content_outlets  enable row level security;
alter table public.content_settings enable row level security;
alter table public.access_links     enable row level security;

revoke all on public.content_items, public.content_outlets,
              public.content_settings, public.access_links from anon, authenticated;

-- ---------- Data awal ----------
insert into public.content_outlets(name, sort) values ('Cafe',1), ('Bengkel',2)
  on conflict do nothing;

insert into public.content_settings(key, value) values
  ('auto_approve','true'),   -- konten AMAN tayang otomatis bila owner diam
  ('auto_hours','24')        -- batas waktu (jam)
  on conflict do nothing;

insert into public.access_links(role, token) values
  ('admin', replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')),
  ('owner', replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''))
  on conflict do nothing;

-- ---------- Fungsi bantu ----------
create or replace function public.cs_role(p_token text) returns text
language sql stable security definer set search_path = public as $$
  select role from public.access_links where token = p_token
$$;

-- ---------- Daftar konten + pengaturan ----------
create or replace function public.cs_list(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.cs_role(p_token);
  v_auto boolean;
  v_hours int;
begin
  if v_role is null then raise exception 'Link tidak valid'; end if;

  v_auto  := coalesce((select value from public.content_settings where key = 'auto_approve'), 'true') = 'true';
  v_hours := coalesce((select value::int from public.content_settings where key = 'auto_hours'), 24);

  -- Konten AMAN yang melewati batas waktu otomatis dianggap disetujui.
  if v_auto then
    update public.content_items
       set status = 'Disetujui', auto_approved = true, decided_at = now(), updated_at = now()
     where status = 'Menunggu Approval' and kind = 'AMAN'
       and submitted_at <= now() - make_interval(hours => v_hours);
  end if;

  return jsonb_build_object(
    'role', v_role,
    'now', now(),
    'settings', jsonb_build_object('auto_approve', v_auto, 'auto_hours', v_hours),
    'outlets', (select coalesce(jsonb_agg(name order by sort, name), '[]'::jsonb) from public.content_outlets),
    'items', (
      select coalesce(jsonb_agg(
               case when v_role = 'admin' then to_jsonb(i) else to_jsonb(i) - 'raw_url' - 'pic' end
               order by i.planned_date nulls last, i.created_at), '[]'::jsonb)
        from public.content_items i
       where v_role = 'admin'
          or i.status in ('Menunggu Approval','Disetujui','Ditolak','Terjadwal','Sudah Tayang')
    )
  );
end $$;

-- ---------- Simpan / ubah konten (admin) ----------
create or replace function public.cs_save_item(p_token text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid := nullif(p->>'id', '')::uuid;
  v_old public.content_items;
  v_new public.content_items;
  v_reset boolean := false;
begin
  if public.cs_role(p_token) is distinct from 'admin' then raise exception 'Hanya admin'; end if;
  if coalesce(trim(p->>'title'), '') = '' then raise exception 'Judul wajib diisi'; end if;
  if coalesce(trim(p->>'outlet'), '') = '' then raise exception 'Outlet wajib dipilih'; end if;
  if coalesce(p->>'kind', 'AMAN') not in ('AMAN','SENSITIF') then raise exception 'Jenis konten tidak valid'; end if;

  if v_id is null then
    insert into public.content_items(outlet, planned_date, platform, kind, title, caption, hashtags,
                                     raw_url, edit_url, pic, status)
    values (p->>'outlet', nullif(p->>'planned_date','')::date,
            coalesce(nullif(p->>'platform',''), 'Instagram + TikTok'),
            coalesce(p->>'kind','AMAN'), trim(p->>'title'),
            coalesce(p->>'caption',''), coalesce(p->>'hashtags',''),
            coalesce(p->>'raw_url',''), coalesce(p->>'edit_url',''), coalesce(p->>'pic',''),
            case when coalesce(p->>'status','') in ('Ide','Menunggu Bahan','Bahan Masuk','Diedit')
                 then p->>'status' else 'Ide' end)
    returning * into v_new;
  else
    select * into v_old from public.content_items where id = v_id;
    if not found then raise exception 'Konten tidak ditemukan'; end if;

    -- Jika isi yang dilihat owner berubah setelah dikirim/disetujui, approval harus diulang.
    v_reset := v_old.status in ('Menunggu Approval','Disetujui','Terjadwal') and (
         v_old.title    is distinct from trim(p->>'title')
      or v_old.caption  is distinct from coalesce(p->>'caption','')
      or v_old.hashtags is distinct from coalesce(p->>'hashtags','')
      or v_old.edit_url is distinct from coalesce(p->>'edit_url','')
      or v_old.kind     is distinct from coalesce(p->>'kind','AMAN'));

    update public.content_items set
      outlet = p->>'outlet',
      planned_date = nullif(p->>'planned_date','')::date,
      platform = coalesce(nullif(p->>'platform',''), 'Instagram + TikTok'),
      kind = coalesce(p->>'kind','AMAN'),
      title = trim(p->>'title'),
      caption = coalesce(p->>'caption',''),
      hashtags = coalesce(p->>'hashtags',''),
      raw_url = coalesce(p->>'raw_url',''),
      edit_url = coalesce(p->>'edit_url',''),
      pic = coalesce(p->>'pic',''),
      status = case when v_reset then 'Diedit' else status end,
      submitted_at = case when v_reset then null else submitted_at end,
      decided_at = case when v_reset then null else decided_at end,
      auto_approved = case when v_reset then false else auto_approved end,
      owner_note = case when v_reset then '' else owner_note end,
      updated_at = now()
    where id = v_id
    returning * into v_new;
  end if;

  return jsonb_build_object('item', to_jsonb(v_new), 'reset', v_reset);
end $$;

-- ---------- Ganti status (admin; bukan approval) ----------
create or replace function public.cs_set_status(p_token text, p_id uuid, p_status text, p_posted_url text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_old public.content_items; v_new public.content_items;
begin
  if public.cs_role(p_token) is distinct from 'admin' then raise exception 'Hanya admin'; end if;
  select * into v_old from public.content_items where id = p_id;
  if not found then raise exception 'Konten tidak ditemukan'; end if;

  if p_status not in ('Ide','Menunggu Bahan','Bahan Masuk','Diedit','Terjadwal','Sudah Tayang') then
    raise exception 'Status ini hanya bisa diubah lewat alur kirim/approval';
  end if;
  if p_status in ('Terjadwal','Sudah Tayang') and v_old.status not in ('Disetujui','Terjadwal','Sudah Tayang') then
    raise exception 'Konten belum disetujui owner, belum boleh dijadwalkan atau ditayangkan';
  end if;

  update public.content_items set
    status = p_status,
    posted_url = case when p_status = 'Sudah Tayang' then coalesce(nullif(p_posted_url,''), posted_url) else posted_url end,
    submitted_at  = case when p_status in ('Terjadwal','Sudah Tayang') then submitted_at else null end,
    decided_at    = case when p_status in ('Terjadwal','Sudah Tayang') then decided_at else null end,
    auto_approved = case when p_status in ('Terjadwal','Sudah Tayang') then auto_approved else false end,
    updated_at = now()
  where id = p_id returning * into v_new;
  return to_jsonb(v_new);
end $$;

-- ---------- Kirim batch ke owner (admin) ----------
create or replace function public.cs_submit(p_token text, p_ids uuid[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if public.cs_role(p_token) is distinct from 'admin' then raise exception 'Hanya admin'; end if;
  update public.content_items set
    status = 'Menunggu Approval', submitted_at = now(), decided_at = null,
    auto_approved = false, owner_note = '', updated_at = now()
  where id = any(p_ids)
    and status in ('Bahan Masuk','Diedit','Ditolak')
    and edit_url <> '';
  get diagnostics v_n = row_count;
  return jsonb_build_object('submitted', v_n, 'skipped', coalesce(array_length(p_ids,1),0) - v_n);
end $$;

-- ---------- Keputusan owner ----------
create or replace function public.cs_decide(p_token text, p_ids uuid[], p_decision text, p_note text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if public.cs_role(p_token) is distinct from 'owner' then raise exception 'Hanya owner yang bisa memutuskan'; end if;
  if p_decision not in ('Disetujui','Ditolak') then raise exception 'Keputusan tidak valid'; end if;
  update public.content_items set
    status = p_decision, decided_at = now(), auto_approved = false,
    owner_note = coalesce(p_note,''), updated_at = now()
  where id = any(p_ids) and status = 'Menunggu Approval';
  get diagnostics v_n = row_count;
  return jsonb_build_object('updated', v_n);
end $$;

-- ---------- Hapus konten (admin) ----------
create or replace function public.cs_delete_item(p_token text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if public.cs_role(p_token) is distinct from 'admin' then raise exception 'Hanya admin'; end if;
  delete from public.content_items where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Daftar outlet (admin) ----------
create or replace function public.cs_outlets_set(p_token text, p_names text[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_names text[];
begin
  if public.cs_role(p_token) is distinct from 'admin' then raise exception 'Hanya admin'; end if;
  select coalesce(array_agg(n order by o), '{}') into v_names
    from (select trim(x) n, min(ord) o from unnest(p_names) with ordinality as t(x, ord)
           where trim(x) <> '' group by trim(x)) s;
  if coalesce(array_length(v_names,1),0) = 0 then raise exception 'Minimal satu outlet'; end if;
  delete from public.content_outlets where name <> all(v_names);
  insert into public.content_outlets(name, sort)
    select n, o::int from unnest(v_names) with ordinality as t(n, o)
  on conflict (name) do update set sort = excluded.sort;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Pengaturan (admin) ----------
create or replace function public.cs_set_setting(p_token text, p_key text, p_value text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if public.cs_role(p_token) is distinct from 'admin' then raise exception 'Hanya admin'; end if;
  if p_key = 'auto_approve' and p_value in ('true','false') then null;
  elsif p_key = 'auto_hours' and p_value ~ '^[0-9]+$' and p_value::int between 1 and 168 then null;
  else raise exception 'Pengaturan tidak valid'; end if;
  insert into public.content_settings(key, value) values (p_key, p_value)
    on conflict (key) do update set value = excluded.value;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Link rahasia (admin) ----------
create or replace function public.cs_links(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if public.cs_role(p_token) is distinct from 'admin' then raise exception 'Hanya admin'; end if;
  return (select jsonb_object_agg(role, token) from public.access_links);
end $$;

create or replace function public.cs_rotate_link(p_token text, p_role text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_new text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
begin
  if public.cs_role(p_token) is distinct from 'admin' then raise exception 'Hanya admin'; end if;
  if p_role not in ('admin','owner') then raise exception 'Peran tidak valid'; end if;
  update public.access_links set token = v_new where role = p_role;
  return jsonb_build_object('role', p_role, 'token', v_new);
end $$;

-- ---------- Izin eksekusi ----------
revoke all on function public.cs_role(text) from public, anon, authenticated;

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname like 'cs\_%' and p.proname <> 'cs_role'
  loop
    execute format('revoke all on function %s from public', f.sig);
    execute format('grant execute on function %s to anon, authenticated', f.sig);
  end loop;
end $$;

-- ---------- Ambil link rahasia ----------
-- Salin nilai token. Format link: https://DOMAIN-ANDA/?k=TOKEN
select role, token from public.access_links order by role;

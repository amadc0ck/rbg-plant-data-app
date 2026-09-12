-- 001_schema.sql -- RBG Plant Data app, Supabase project jkrsdvjrnsrjowhaobsr
-- Applied 2026-09-12 via `supabase db query --linked`. No migration tool:
-- every schema change is a new numbered file here, applied once.
--
-- Access model:
--   * Nothing is readable without signing in AND being in public.staff.
--   * The bot (GitHub Actions) writes source_records with the secret key,
--     which bypasses RLS -- so source_records has no write policies at all.
--   * Staff read everything and write name_merges / not_duplicates.
--   * Only admins add or remove staff.

begin;

-- ---------------------------------------------------------------- staff

create table public.staff (
  email        text primary key check (email = lower(email)),
  display_name text,
  is_admin     boolean not null default false,
  added_by     text,
  added_at     timestamptz not null default now()
);

-- security definer so policies on staff itself can call these without
-- recursing through staff's own RLS.
create or replace function public.current_email() returns text
  language sql stable set search_path = ''
as $$ select lower(coalesce(auth.jwt() ->> 'email', '')) $$;

create or replace function public.is_staff() returns boolean
  language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.staff s where s.email = public.current_email()) $$;

create or replace function public.is_admin() returns boolean
  language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.staff s where s.email = public.current_email() and s.is_admin) $$;

alter table public.staff enable row level security;
create policy staff_read   on public.staff for select to authenticated using (public.is_staff());
create policy staff_insert on public.staff for insert to authenticated with check (public.is_admin());
create policy staff_update on public.staff for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy staff_delete on public.staff for delete to authenticated using (public.is_admin() and email <> public.current_email());

insert into public.staff (email, display_name, is_admin, added_by)
values ('me@justamanda.net', 'Amanda Adcock', true, 'setup');

-- ------------------------------------------------------- source_records
-- One row per record in a source, refreshed by the bot every run.
--   tumblr   source_id = Tumblr post id
--   website  source_id = Plant Highlight URL
--   wib      source_id = name_key (the What's in Bloom tab is one row per plant)
-- name_key is computed by the bot (rbg-tumblr-plant-bot/scripts/names.py)
-- so there is exactly one definition of it; the app never recomputes it.

create table public.source_records (
  id               bigint generated always as identity primary key,
  source           text not null check (source in ('tumblr', 'website', 'wib')),
  source_id        text not null,
  plant_name       text not null,
  name_key         text not null,
  description      text,
  photo_url        text,
  detail_photo_url text,
  link             text,
  posted_at        timestamptz,
  tags             text[] not null default '{}',
  details          jsonb not null default '{}',
  synced_at        timestamptz not null default now(),
  unique (source, source_id)
);
create index source_records_name_key on public.source_records (name_key);

alter table public.source_records enable row level security;
create policy source_records_read on public.source_records for select to authenticated using (public.is_staff());

-- ---------------------------------------------------------- name_merges
-- "alias_key is the same plant as canonical_key". Kept flat by trigger:
-- a canonical is never itself an alias, so one lookup always resolves.

create table public.name_merges (
  alias_key      text primary key,
  canonical_key  text not null,
  alias_name     text not null,
  canonical_name text not null,
  merged_by      text not null default public.current_email(),
  merged_at      timestamptz not null default now(),
  check (alias_key <> canonical_key)
);
create index name_merges_canonical on public.name_merges (canonical_key);

create or replace function public.name_merges_flatten() returns trigger
  language plpgsql set search_path = ''
as $$
declare
  final_key  text;
  final_name text;
begin
  -- Merging into something that is already an alias: point at its canonical.
  select m.canonical_key, m.canonical_name into final_key, final_name
    from public.name_merges m where m.alias_key = new.canonical_key;
  if found then
    new.canonical_key  := final_key;
    new.canonical_name := final_name;
  end if;
  if new.canonical_key = new.alias_key then
    raise exception 'Merge would point % at itself', new.alias_name;
  end if;
  -- Anything that pointed at this alias now points at the new canonical.
  update public.name_merges m
     set canonical_key = new.canonical_key, canonical_name = new.canonical_name
   where m.canonical_key = new.alias_key;
  return new;
end $$;

create trigger name_merges_flatten before insert or update on public.name_merges
  for each row execute function public.name_merges_flatten();

alter table public.name_merges enable row level security;
create policy name_merges_read   on public.name_merges for select to authenticated using (public.is_staff());
create policy name_merges_insert on public.name_merges for insert to authenticated
  with check (public.is_staff() and merged_by = public.current_email());
create policy name_merges_update on public.name_merges for update to authenticated
  using (public.is_staff()) with check (public.is_staff());
create policy name_merges_delete on public.name_merges for delete to authenticated using (public.is_staff());

-- ------------------------------------------------------- not_duplicates
-- Pairs someone looked at and said "different plants". Stored in sorted
-- order so (a,b) and (b,a) are the same row.

create table public.not_duplicates (
  key_a     text not null,
  key_b     text not null,
  marked_by text not null default public.current_email(),
  marked_at timestamptz not null default now(),
  primary key (key_a, key_b),
  check (key_a < key_b)
);

alter table public.not_duplicates enable row level security;
create policy not_duplicates_read   on public.not_duplicates for select to authenticated using (public.is_staff());
create policy not_duplicates_insert on public.not_duplicates for insert to authenticated
  with check (public.is_staff() and marked_by = public.current_email());
create policy not_duplicates_delete on public.not_duplicates for delete to authenticated using (public.is_staff());

-- ---------------------------------------------------------------- grants
-- RLS decides rows; these decide which roles may try at all. anon gets nothing.

revoke all on public.staff, public.source_records, public.name_merges, public.not_duplicates from anon;
grant select, insert, update, delete on public.staff          to authenticated;
grant select                         on public.source_records to authenticated;
grant select, insert, update, delete on public.name_merges    to authenticated;
grant select, insert, delete         on public.not_duplicates to authenticated;
revoke execute on function public.is_staff(), public.is_admin(), public.current_email() from anon;

commit;

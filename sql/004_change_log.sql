-- 004_change_log.sql -- who changed what, for every table a person edits.
-- Applied 2026-09-16 via `supabase db query --linked --project-ref ...`.
--
-- WHY A TRIGGER AND NOT APP CODE: the app is one of three writers (the app,
-- the bot, and SQL run by hand). A trigger catches all three, and can't be
-- forgotten when a new screen is added.
--
-- WHAT IS NOT LOGGED: public.source_records. The bot rewrites Tumblr /
-- Highlight / What's in Bloom rows on every run, and thousands of scraper
-- rows per run would bury the handful of human edits (decided 2026-09-16).
-- IrisBG source rows are excluded for the same reason -- what an import did
-- is summarised in public.irisbg_imports, which IS logged.
--
-- NOT BACKFILLED: no history exists before this file ran. Rows carry only
-- updated_at / updated_by, so the log starts empty.
--
-- WHO: a signed-in person's email, or 'system' when there is no JWT -- the
-- bot's service key and any SQL run from the CLI both look like that.
--
-- READING IT: the app never syncs this table into its local cache (it grows
-- forever and the free egress budget is shared with the ABG app) -- it is
-- queried on demand, filtered by name_key or ordered by changed_at.

begin;

create table public.change_log (
  id          bigint generated always as identity primary key,
  table_name  text not null,
  row_key     text,          -- how a person recognises the row: a display name, an accession number
  name_key    text,          -- the plant it belongs to, when the row belongs to one
  op          text not null check (op in ('insert', 'update', 'delete')),
  changed_by  text not null,
  changed_at  timestamptz not null default now(),
  -- {"field": {"from": <old>, "to": <new>}} -- only fields that actually changed
  changes     jsonb not null default '{}'
);
create index change_log_recent   on public.change_log (changed_at desc);
create index change_log_name_key on public.change_log (name_key, changed_at desc);
create index change_log_row      on public.change_log (table_name, row_key, changed_at desc);

alter table public.change_log enable row level security;
-- Read-only to everyone: the trigger below is security definer, so it writes
-- as the table's owner and needs no policy of its own. Nobody can rewrite
-- history through the API.
create policy change_log_read on public.change_log for select to authenticated using (public.is_staff());
revoke all on public.change_log from anon;
grant select on public.change_log to authenticated;

-- Bookkeeping columns say nothing a person wants to read in a history list:
-- updated_at/by is already the log row's own timestamp and author, and
-- last_import_id changes on every IrisBG import with no meaning to a reader.
-- in_latest_export is deliberately NOT skipped -- "dropped out of IrisBG" matters.
create or replace function public.log_change() returns trigger
  language plpgsql security definer set search_path = ''
as $$
declare
  o       jsonb := case when tg_op = 'INSERT' then '{}'::jsonb else to_jsonb(old) end;
  n       jsonb := case when tg_op = 'DELETE' then '{}'::jsonb else to_jsonb(new) end;
  diff    jsonb := '{}'::jsonb;
  k       text;
  ov      jsonb;
  nv      jsonb;
  skipped text[] := array['id', 'created_at', 'updated_at', 'updated_by', 'synced_at', 'last_import_id', 'content_hash'];
  rkey    text;
  nkey    text;
begin
  for k in select jsonb_object_keys(o || n) loop
    continue when k = any (skipped);
    ov := o -> k;
    nv := n -> k;
    if ov is distinct from nv then
      -- A jsonb null and a missing key both read as SQL NULL here, which is
      -- what the app shows as "—".
      diff := diff || jsonb_build_object(k, jsonb_build_object('from', ov, 'to', nv));
    end if;
  end loop;

  if diff = '{}'::jsonb and tg_op = 'UPDATE' then
    return null;   -- a touch that changed nothing real (e.g. only updated_at)
  end if;

  if tg_table_name = 'taxa' then
    rkey := coalesce(n ->> 'display_name', o ->> 'display_name');
    nkey := coalesce(n ->> 'name_key', o ->> 'name_key');
  elsif tg_table_name = 'accessions' then
    rkey := coalesce(n ->> 'accession_number', o ->> 'accession_number');
    nkey := coalesce(n ->> 'name_key', o ->> 'name_key');
  elsif tg_table_name = 'plantings' then
    select a.accession_number || '/' || coalesce(coalesce(n ->> 'item_qualifier', o ->> 'item_qualifier'), '?'), a.name_key
      into rkey, nkey
      from public.accessions a
     where a.id = (coalesce(n ->> 'accession_id', o ->> 'accession_id'))::bigint;
  elsif tg_table_name = 'name_merges' then
    rkey := coalesce(n ->> 'alias_name', o ->> 'alias_name') || ' → ' || coalesce(n ->> 'canonical_name', o ->> 'canonical_name');
    nkey := coalesce(n ->> 'canonical_key', o ->> 'canonical_key');
  elsif tg_table_name = 'not_duplicates' then
    rkey := coalesce(n ->> 'key_a', o ->> 'key_a') || ' / ' || coalesce(n ->> 'key_b', o ->> 'key_b');
    nkey := coalesce(n ->> 'key_a', o ->> 'key_a');
  elsif tg_table_name = 'staff' then
    rkey := coalesce(n ->> 'email', o ->> 'email');
  elsif tg_table_name = 'list_options' then
    rkey := coalesce(n ->> 'list', o ->> 'list') || ': ' || coalesce(n ->> 'value', o ->> 'value');
  elsif tg_table_name = 'garden_locations' then
    rkey := coalesce(n ->> 'name', o ->> 'name', '') || ' (' || coalesce(n ->> 'code', o ->> 'code') || ')';
  elsif tg_table_name = 'irisbg_imports' then
    rkey := coalesce(n ->> 'file_name', o ->> 'file_name');
  else
    rkey := null;
  end if;

  insert into public.change_log (table_name, row_key, name_key, op, changed_by, changes)
  values (tg_table_name, rkey, nkey, lower(tg_op),
          coalesce(nullif(public.current_email(), ''), 'system'), diff);
  return null;
end $$;

create trigger taxa_log             after insert or update or delete on public.taxa             for each row execute function public.log_change();
create trigger accessions_log       after insert or update or delete on public.accessions       for each row execute function public.log_change();
create trigger plantings_log        after insert or update or delete on public.plantings        for each row execute function public.log_change();
create trigger name_merges_log      after insert or update or delete on public.name_merges      for each row execute function public.log_change();
create trigger not_duplicates_log   after insert or update or delete on public.not_duplicates   for each row execute function public.log_change();
create trigger staff_log            after insert or update or delete on public.staff            for each row execute function public.log_change();
create trigger list_options_log     after insert or update or delete on public.list_options     for each row execute function public.log_change();
create trigger garden_locations_log after insert or update or delete on public.garden_locations for each row execute function public.log_change();
create trigger irisbg_imports_log   after insert or update or delete on public.irisbg_imports   for each row execute function public.log_change();

commit;

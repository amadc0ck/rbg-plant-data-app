-- 007_archived_names.sql -- names the app should stop treating as plants.
-- Applied 2026-09-18 via `supabase db query --linked --project-ref ...`.
--
-- WHY NOT JUST DELETE: a "plant" in this app is not a row. It is whatever
-- the four sources say under one matching name, assembled in the browser.
-- Deleting the Tumblr post or the What's in Bloom appearance that produced
-- a bad name would work until the next bot run re-created it from the same
-- PDF -- and it would also throw away evidence of what the garden actually
-- published. So the source record stays exactly as scraped and the NAME is
-- marked as not-a-plant. The app then leaves it out of Browse, the
-- dashboard counts and the duplicate suggestions.
--
-- WHAT GETS ARCHIVED: page furniture the PDF reader mistook for a plant
-- ("Join the Curator for a virtual What's in Bloom tour", "Aizoaceae seed
-- capsules"), two plants typed into one label, and -- a different thing
-- entirely -- a real plant that has left the collection, which keeps its
-- history but drops out of the working lists.
--
-- REVERSIBLE: restoring is deleting the row here. Both directions are
-- recorded in change_log by the trigger at the bottom.

begin;

create table public.archived_names (
  name_key     text primary key,
  display_name text not null,
  reason       text not null check (reason in ('not_a_plant', 'two_plants', 'duplicate', 'left_collection', 'other')),
  note         text,
  archived_by  text not null default public.current_email(),
  archived_at  timestamptz not null default now()
);

alter table public.archived_names enable row level security;
create policy archived_names_read   on public.archived_names for select to authenticated using (public.is_staff());
create policy archived_names_insert on public.archived_names for insert to authenticated
  with check (public.is_staff() and archived_by = public.current_email());
create policy archived_names_update on public.archived_names for update to authenticated
  using (public.is_staff()) with check (public.is_staff());
create policy archived_names_delete on public.archived_names for delete to authenticated using (public.is_staff());
revoke all on public.archived_names from anon;
grant select, insert, update, delete on public.archived_names to authenticated;

-- Give the history log a readable name for these rows, then log them.
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
      diff := diff || jsonb_build_object(k, jsonb_build_object('from', ov, 'to', nv));
    end if;
  end loop;

  if diff = '{}'::jsonb and tg_op = 'UPDATE' then
    return null;
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
  elsif tg_table_name = 'archived_names' then
    rkey := coalesce(n ->> 'display_name', o ->> 'display_name');
    nkey := coalesce(n ->> 'name_key', o ->> 'name_key');
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

create trigger archived_names_log after insert or update or delete on public.archived_names
  for each row execute function public.log_change();

commit;

-- 009_app_settings.sql -- garden-wide switches an admin sets for everyone.
--
-- First (and so far only) key: include_irisbg. v1.13.0 shipped it as a
-- per-browser checkbox in the nav; Amanda moved it to Admin -> App
-- Settings in v1.14.0, which makes it shared state -- one answer for every
-- staff member -- so it has to live in the database, not localStorage.
--
-- Key/value rather than one column per setting so the next switch is a
-- row, not another schema change. Staff read, admins write. Changes are
-- recorded in change_log by the trigger at the bottom (row_key is left
-- blank there; the logged diff carries the key and both values).

begin;

create table public.app_settings (
  key        text primary key,
  value      jsonb not null,
  updated_by text not null default public.current_email(),
  updated_at timestamptz not null default now()
);

alter table public.app_settings enable row level security;
create policy app_settings_read   on public.app_settings for select to authenticated using (public.is_staff());
create policy app_settings_insert on public.app_settings for insert to authenticated with check (public.is_admin());
create policy app_settings_update on public.app_settings for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy app_settings_delete on public.app_settings for delete to authenticated using (public.is_admin());
revoke all on public.app_settings from anon;
grant select, insert, update, delete on public.app_settings to authenticated;

insert into public.app_settings (key, value, updated_by) values ('include_irisbg', 'true'::jsonb, 'system');

create trigger app_settings_log after insert or update or delete on public.app_settings
  for each row execute function public.log_change();

commit;

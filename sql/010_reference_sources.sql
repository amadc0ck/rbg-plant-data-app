-- 010_reference_sources.sql -- which outside lookup sources are approved.
--
-- WHY: the name check and the curated-field suggestions lean on outside
-- sources (sql/005): the Global Biodiversity Information Facility for
-- botanical names, five nurseries for cultivars and garden facts. Which of
-- them the garden trusts is a curator's call, so it is a list admins edit
-- under Admin -> App Settings rather than something fixed in code.
--
-- status:
--   approved   -- the app shows its data; the bot fetches it
--   off        -- the app hides its data; the bot skips it. Rows already
--                 fetched are KEPT, so switching back on restores everything
--   requested  -- someone wants it added. Every source is its own
--                 hand-written reader in rbg-tumblr-plant-bot, so a request
--                 is a to-do for a development session, not a working source
--
-- reference_names.source keeps its own check constraint: a new reader is
-- code anyway, and that session widens the constraint when it adds one.

begin;

create table public.reference_sources (
  source         text primary key check (source ~ '^[a-z0-9_]+$'),
  label          text not null,
  kind           text not null check (kind in ('botanical', 'nursery', 'other')),
  url            text,
  purpose        text,
  status         text not null default 'requested' check (status in ('approved', 'off', 'requested')),
  requested_by   text,
  requested_note text,
  updated_by     text not null default public.current_email(),
  updated_at     timestamptz not null default now()
);

alter table public.reference_sources enable row level security;
create policy reference_sources_read   on public.reference_sources for select to authenticated using (public.is_staff());
create policy reference_sources_insert on public.reference_sources for insert to authenticated with check (public.is_admin());
create policy reference_sources_update on public.reference_sources for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy reference_sources_delete on public.reference_sources for delete to authenticated using (public.is_admin());
revoke all on public.reference_sources from anon;
grant select, insert, update, delete on public.reference_sources to authenticated;

insert into public.reference_sources (source, label, kind, url, purpose, status, updated_by) values
  ('gbif', 'Global Biodiversity Information Facility', 'botanical', 'https://www.gbif.org/',
   'Whether a species name is accepted, an old synonym, or unknown; and the family.', 'approved', 'system'),
  ('smgrowers', 'San Marcos Growers', 'nursery', 'https://www.smgrowers.com/',
   'Cultivar and trade names; sun, water, size and hardiness in garden terms.', 'approved', 'system'),
  ('anniesannuals', 'Annie''s Annuals', 'nursery', 'https://www.anniesannuals.com/',
   'Cultivar and trade names; sun, water, size and hardiness in garden terms.', 'approved', 'system'),
  ('floragrubb', 'Flora Grubb', 'nursery', 'https://www.floragrubb.com/',
   'Cultivar and trade names; sun, water, size and hardiness in garden terms.', 'approved', 'system'),
  ('waltzingmatilija', 'Waltzing Matilija', 'nursery', 'https://www.waltzingmatilija.com/',
   'Cultivar and trade names; sun, water, size and hardiness in garden terms.', 'approved', 'system'),
  ('crescenthill', 'Crescent Hill Nursery', 'nursery', 'https://crescenthillnursery.com/',
   'Cultivar and trade names; sun, water, size and hardiness in garden terms.', 'approved', 'system');

create trigger reference_sources_log after insert or update or delete on public.reference_sources
  for each row execute function public.log_change();

commit;

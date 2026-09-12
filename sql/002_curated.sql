-- 002_curated.sql -- curated taxon records, IrisBG accessions/plantings,
-- What's in Bloom editions, picklists. Applied via `supabase db query --linked`.
--
-- Model (decided 2026-09-12):
--   taxon      one curated record per plant (a merged name group)
--   accession  from IrisBG; many per taxon          e.g. 2016-0059
--   planting   an IrisBG "item"; many per accession  e.g. 2016-0059/1, /A
--              -- location and GPS live HERE, because one accession can be
--              split across beds.
--
-- Everything that links to "a plant" links by name_key, never by id, so a
-- merge in name_merges re-homes accessions, bloom appearances and source
-- records automatically. Only taxa carry the key as their identity, and the
-- name_merges trigger below moves a taxon when its name is merged away.

begin;

-- ------------------------------------------------------------ name_key()
-- The single matching rule, now in the database so the bot, the app and the
-- in-browser IrisBG import all get it from one place. It is a port of
-- rbg-tumblr-plant-bot/scripts/names.py and was verified identical on all
-- 3,590 distinct names across Tumblr, website, What's in Bloom and IrisBG
-- (plus edge cases) before this was applied. Change both or neither.
-- Postgres regex uses \y for a word boundary where Python uses \b.

create or replace function public.name_key(name text) returns text
  language sql immutable parallel safe set search_path = ''
as $f$
  select regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
         regexp_replace(regexp_replace(regexp_replace(regexp_replace(
           lower(regexp_replace(
             btrim(translate(normalize(coalesce(name, ''), NFKC), E'​‌‍﻿', '')),
             '^(?:×\s*|x\s+(?=[A-Z]))', '')),
           '[‘’‚‛`´′]', '''', 'g'),
           '[“”„‟″"]', '''', 'g'),
           '\s*×\s*', ' x ', 'g'),
           '\ysubsp\y\.?', 'ssp.', 'g'),
           '\yssp\y\.?', 'ssp.', 'g'),
           '\yv(?:ar)?\y\.?(?=\s)', 'var.', 'g'),
           '\(\s+', '(', 'g'),
           '\s+\)', ')', 'g'),
           '\s+', ' ', 'g'),
           '^[ \-–—.,;:]+|[ \-–—.,;:]+$', '', 'g')
$f$;

-- source_records.name_key becomes computed by the database. The bot stops
-- sending it; rows are re-derived in place.
alter table public.source_records drop column name_key;
alter table public.source_records
  add column name_key text generated always as (public.name_key(plant_name)) stored;
create index source_records_name_key on public.source_records (name_key);

-- IrisBG rows are uploaded from the app by an admin, so admins may write
-- that one source. Bot sources stay bot-only.
alter table public.source_records drop constraint source_records_source_check;
alter table public.source_records
  add constraint source_records_source_check check (source in ('tumblr', 'website', 'wib', 'irisbg'));
create policy source_records_irisbg_insert on public.source_records for insert to authenticated
  with check (public.is_admin() and source = 'irisbg');
create policy source_records_irisbg_update on public.source_records for update to authenticated
  using (public.is_admin() and source = 'irisbg') with check (public.is_admin() and source = 'irisbg');
create policy source_records_irisbg_delete on public.source_records for delete to authenticated
  using (public.is_admin() and source = 'irisbg');
grant insert, update, delete on public.source_records to authenticated;

-- Shared: stamp updated_at / updated_by on every edit.
create or replace function public.touch_updated() returns trigger
  language plpgsql set search_path = ''
as $$
begin
  new.updated_at := now();
  new.updated_by := coalesce(nullif(public.current_email(), ''), 'bot');
  return new;
end $$;

-- ------------------------------------------------------------ list_options
-- Picklists. Values are what gets stored, so renaming one means updating
-- the rows that use it -- the app does that, not a foreign key.

create table public.list_options (
  list  text not null check (list in ('plant_type', 'light_needs', 'water_needs', 'blooming_season')),
  value text not null,
  sort  int  not null default 0,
  primary key (list, value)
);
alter table public.list_options enable row level security;
create policy list_options_read  on public.list_options for select to authenticated using (public.is_staff());
create policy list_options_write on public.list_options for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.list_options to authenticated;

-- Starter values, to be edited in the app. Water needs follow WUCOLS, the
-- California landscape water-use standard. Light needs are refined once the
-- What's in Bloom "Sun/Shade" values are in the database.
insert into public.list_options (list, value, sort) values
  ('plant_type', 'Cactus', 1), ('plant_type', 'Succulent', 2), ('plant_type', 'Tree', 3),
  ('plant_type', 'Shrub', 4), ('plant_type', 'Perennial', 5), ('plant_type', 'Bulb / geophyte', 6),
  ('plant_type', 'Grass', 7), ('plant_type', 'Groundcover', 8), ('plant_type', 'Vine', 9),
  ('plant_type', 'Palm', 10), ('plant_type', 'Cycad', 11), ('plant_type', 'Annual', 12),
  ('light_needs', 'Full sun', 1), ('light_needs', 'Full sun to part shade', 2),
  ('light_needs', 'Part shade', 3), ('light_needs', 'Shade', 4),
  ('water_needs', 'Very low', 1), ('water_needs', 'Low', 2),
  ('water_needs', 'Moderate', 3), ('water_needs', 'High', 4),
  ('blooming_season', 'Winter', 1), ('blooming_season', 'Spring', 2),
  ('blooming_season', 'Summer', 3), ('blooming_season', 'Fall', 4);

-- ------------------------------------------------------------------- taxa

create table public.taxa (
  id              bigint generated always as identity primary key,
  name_key        text not null unique,   -- canonical key of the merged name group
  display_name    text not null,
  family          text,
  genus           text,
  species         text,
  infra_rank      text check (infra_rank in ('ssp.', 'var.', 'f.')),
  infra_epithet   text,
  cultivar        text,
  hybrid_formula  text,
  common_name     text,
  plant_type      text,
  native_to       text,
  native_to_ca    boolean,
  form_size       text,
  light_needs     text,
  hardiness       text,
  water_needs     text,
  blooming_season text[] not null default '{}',
  -- IUCN Red List category codes, least to most threatened, plus
  -- NE (not evaluated) and DD (data deficient).
  conservation_status        text check (conservation_status in ('NE','DD','LC','NT','VU','EN','CR','EW','EX')),
  conservation_assessed_year int  check (conservation_assessed_year between 1960 and 2100),
  conservation_url           text,
  notes           text,
  -- Where each field's value came from:
  --   {"hardiness": {"source": "wib", "source_record_id": 123, "by": "...", "at": "..."}}
  -- source is one of tumblr | website | wib | irisbg | iucn | manual | derived.
  provenance      jsonb not null default '{}',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  updated_by      text
);
create trigger taxa_touch before update on public.taxa for each row execute function public.touch_updated();

alter table public.taxa enable row level security;
create policy taxa_read   on public.taxa for select to authenticated using (public.is_staff());
create policy taxa_insert on public.taxa for insert to authenticated with check (public.is_staff());
create policy taxa_update on public.taxa for update to authenticated using (public.is_staff()) with check (public.is_staff());
create policy taxa_delete on public.taxa for delete to authenticated using (public.is_admin());
grant select, insert, update, delete on public.taxa to authenticated;

-- A merge moves the alias's curated record to the canonical name -- unless
-- both already have one, in which case a person has to reconcile them first.
create or replace function public.name_merges_move_taxon() returns trigger
  language plpgsql set search_path = ''
as $$
begin
  if exists (select 1 from public.taxa where name_key = new.alias_key) then
    if exists (select 1 from public.taxa where name_key = new.canonical_key) then
      raise exception 'Both "%" and "%" have curated records. Copy what you need into one and delete the other before merging.',
        new.alias_name, new.canonical_name;
    end if;
    update public.taxa set name_key = new.canonical_key, display_name = new.canonical_name
     where name_key = new.alias_key;
  end if;
  return new;
end $$;
create trigger name_merges_move_taxon after insert on public.name_merges
  for each row execute function public.name_merges_move_taxon();

-- ---------------------------------------------------------- garden_locations
-- IrisBG location codes ("H", "H-W", "ESH-CB", "KIOSK") and their real names.

create table public.garden_locations (
  code        text primary key,
  name        text,
  parent_code text references public.garden_locations (code),
  notes       text
);
alter table public.garden_locations enable row level security;
create policy garden_locations_read  on public.garden_locations for select to authenticated using (public.is_staff());
create policy garden_locations_write on public.garden_locations for all to authenticated
  using (public.is_staff()) with check (public.is_staff());
grant select, insert, update, delete on public.garden_locations to authenticated;

-- ------------------------------------------------------------- irisbg_imports

create table public.irisbg_imports (
  id          bigint generated always as identity primary key,
  file_name   text not null,
  imported_by text not null default public.current_email(),
  imported_at timestamptz not null default now(),
  summary     jsonb not null default '{}'   -- {"accessions_added": n, "plantings_flagged": n, ...}
);
alter table public.irisbg_imports enable row level security;
create policy irisbg_imports_read   on public.irisbg_imports for select to authenticated using (public.is_staff());
create policy irisbg_imports_insert on public.irisbg_imports for insert to authenticated
  with check (public.is_admin() and imported_by = public.current_email());
grant select, insert on public.irisbg_imports to authenticated;

-- ---------------------------------------------------------------- accessions
-- IrisBG export columns -> fields:
--   ItemAccNoFull "2016-0059/1" -> accession_number "2016-0059" (+ planting item "1")
--   TaxonName -> plant_name,  AccNoCons -> irisbg_acc_no_cons (meaning unconfirmed),
--   ContactCode -> contact_code,  OriginName -> origin_name,  AccComment -> comment

create table public.accessions (
  id                  bigint generated always as identity primary key,
  accession_number    text not null unique,
  plant_name          text not null,
  name_key            text generated always as (public.name_key(plant_name)) stored,
  irisbg_acc_no_cons  text,
  contact_code        text,
  origin_name         text,
  comment             text,
  in_latest_export    boolean not null default true,
  last_import_id      bigint references public.irisbg_imports (id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  updated_by          text
);
create index accessions_name_key on public.accessions (name_key);
create trigger accessions_touch before update on public.accessions for each row execute function public.touch_updated();

alter table public.accessions enable row level security;
create policy accessions_read   on public.accessions for select to authenticated using (public.is_staff());
create policy accessions_insert on public.accessions for insert to authenticated with check (public.is_admin());
create policy accessions_update on public.accessions for update to authenticated using (public.is_staff()) with check (public.is_staff());
create policy accessions_delete on public.accessions for delete to authenticated using (public.is_admin());
grant select, insert, update, delete on public.accessions to authenticated;

-- ----------------------------------------------------------------- plantings
-- An IrisBG item. IrisBG fields: ItemLocation "H•H-W•" -> location_code
-- (split into bed "H" / sub_location "H-W"), ItemLocationRef -> location_ref,
-- ItemSpecCount -> specimen_count (text: "Mass" and "clump" occur).
--
-- GPS fields follow how ArcGIS stores a point feature, so a future ArcGIS
-- layer can round-trip: WGS84 decimal degrees (EPSG:4326), and the feature's
-- GlobalID as the stable join key. OBJECTID is deliberately not stored -- it
-- can change when a layer is re-imported. Confirm against RBG's real layer
-- once one exists.

create table public.plantings (
  id                bigint generated always as identity primary key,
  accession_id      bigint not null references public.accessions (id),
  item_qualifier    text not null,
  location_code     text,
  bed               text,
  sub_location      text,
  location_ref      text,
  specimen_count    text,
  status            text not null default 'alive' check (status in ('alive', 'dead', 'removed', 'unknown')),
  in_latest_export  boolean not null default true,
  latitude          numeric(9, 6) check (latitude between -90 and 90),
  longitude         numeric(9, 6) check (longitude between -180 and 180),
  gps_accuracy_m    numeric(7, 2) check (gps_accuracy_m >= 0),
  gps_method        text check (gps_method in ('field_maps_gps', 'map_placed', 'imported', 'other')),
  gps_captured_at   timestamptz,
  gps_captured_by   text,
  arcgis_global_id  uuid unique,
  notes             text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  updated_by        text,
  unique (accession_id, item_qualifier),
  check ((latitude is null) = (longitude is null))
);
create trigger plantings_touch before update on public.plantings for each row execute function public.touch_updated();

alter table public.plantings enable row level security;
create policy plantings_read   on public.plantings for select to authenticated using (public.is_staff());
create policy plantings_insert on public.plantings for insert to authenticated with check (public.is_admin());
create policy plantings_update on public.plantings for update to authenticated using (public.is_staff()) with check (public.is_staff());
create policy plantings_delete on public.plantings for delete to authenticated using (public.is_admin());
grant select, insert, update, delete on public.plantings to authenticated;

-- ------------------------------------------------------ What's in Bloom editions
-- Written by the bot from data/wib_occurrences.csv (the parsed PDFs).

create table public.wib_editions (
  id       bigint generated always as identity primary key,
  year     int  not null check (year between 2000 and 2100),
  month    int  not null check (month between 1 and 12),
  pdf_url  text not null unique
);
create index wib_editions_year_month on public.wib_editions (year, month);

create table public.wib_appearances (
  edition_id  bigint not null references public.wib_editions (id) on delete cascade,
  plant_name  text not null,
  name_key    text generated always as (public.name_key(plant_name)) stored,
  primary key (edition_id, plant_name)
);
create index wib_appearances_name_key on public.wib_appearances (name_key);

alter table public.wib_editions    enable row level security;
alter table public.wib_appearances enable row level security;
create policy wib_editions_read    on public.wib_editions    for select to authenticated using (public.is_staff());
create policy wib_appearances_read on public.wib_appearances for select to authenticated using (public.is_staff());
grant select on public.wib_editions, public.wib_appearances to authenticated;

-- ---------------------------------------------------------------- grants
revoke all on public.list_options, public.taxa, public.garden_locations, public.irisbg_imports,
              public.accessions, public.plantings, public.wib_editions, public.wib_appearances from anon;
revoke execute on function public.name_key(text) from anon;

commit;

-- 005_reference.sql -- name validation against outside sources.
-- Applied 2026-09-18 via `supabase db query --linked --project-ref ...`.
--
-- WHY: the four in-house sources disagree with each other about how a plant
-- is spelled, and none of them is an authority. Two kinds of outside source
-- settle different questions:
--
--   reference_names   five California nurseries (San Marcos Growers, Annie's
--                     Annuals, Flora Grubb, Waltzing Matilija, Crescent Hill).
--                     They are the authority on CULTIVARS, hybrids and trade
--                     names, which botanical databases barely carry, and they
--                     publish sun / water / size / hardiness in garden terms.
--   taxon_matches     GBIF's backbone taxonomy, one row per name_key. It
--                     settles whether a SPECIES name is accepted, a synonym
--                     of something else, or nothing at all, and gives the
--                     family. Kew's POWO has no public API; GBIF carries the
--                     same underlying data and we link out to the POWO page.
--
-- NEITHER IS TRUTH. Both are advice shown next to a curated field, the same
-- way What's in Bloom values are: a person decides. Nothing here ever edits
-- a taxon, and photo_url is a LINK to the nursery's own image -- their
-- photographs are copyrighted and are never copied or republished.
--
-- HOW THE APP READS IT: reference_names is big (thousands of rows with
-- descriptions) and most of it is about plants the garden doesn't grow, so
-- the app syncs only the view reference_names_used -- rows whose name_key
-- matches something in the collection. For a name that matches nothing, the
-- app asks suggest_reference_names() for near spellings instead of holding
-- the whole catalogue in the browser. Egress is shared with the ABG app.

begin;

-- Trigram matching powers "did you mean", server-side. Supabase keeps
-- extensions in their own schema, and every function here pins
-- search_path = '' for safety, so both the operator class and similarity()
-- have to be written out in full.
create extension if not exists pg_trgm with schema extensions;

-- ------------------------------------------------------- reference_names
create table public.reference_names (
  source      text not null check (source in ('smgrowers', 'anniesannuals', 'floragrubb', 'waltzingmatilija', 'crescenthill')),
  source_id   text not null,
  plant_name  text not null,
  name_key    text generated always as (public.name_key(plant_name)) stored,
  url         text,
  photo_url   text,
  -- The nursery's own words, keys among: common_name, family, origin, sun,
  -- water, size, hardiness, bloom_time, plant_type, description.
  facts       jsonb not null default '{}',
  fetched_at  timestamptz not null default now(),
  primary key (source, source_id)
);
create index reference_names_name_key on public.reference_names (name_key);
create index reference_names_trgm     on public.reference_names using gin (plant_name extensions.gin_trgm_ops);
create index reference_names_fetched  on public.reference_names (fetched_at);

alter table public.reference_names enable row level security;
create policy reference_names_read on public.reference_names for select to authenticated using (public.is_staff());
-- Written only by the bot, which uses the secret key and bypasses RLS.
revoke all on public.reference_names from anon;
grant select on public.reference_names to authenticated;

-- --------------------------------------------------------- taxon_matches
-- One row per name_key, not per spelling: the key is what the app groups by.
create table public.taxon_matches (
  name_key          text primary key,
  plant_name        text not null,        -- an example spelling, for reading
  -- How much of the label had to be thrown away to get a hit:
  -- as written | without cultivar | without notes | genus+species | genus only | no match
  matched_as        text not null,
  gbif_key          bigint,
  scientific_name   text,
  canonical_name    text,
  accepted_name     text,                 -- differs from canonical when it is a synonym
  taxonomic_status  text,                 -- ACCEPTED | SYNONYM | DOUBTFUL | ...
  rank              text,
  family            text,
  genus             text,
  confidence        int,
  match_type        text,                 -- EXACT | FUZZY | HIGHERRANK | NONE
  powo_url          text,
  fetched_at        timestamptz not null default now()
);
create index taxon_matches_status on public.taxon_matches (taxonomic_status);
create index taxon_matches_fetched on public.taxon_matches (fetched_at);

alter table public.taxon_matches enable row level security;
create policy taxon_matches_read on public.taxon_matches for select to authenticated using (public.is_staff());
revoke all on public.taxon_matches from anon;
grant select on public.taxon_matches to authenticated;

-- ------------------------------------------------- reference_names_used
-- What the app actually syncs: catalogue entries for plants the garden has,
-- by matching key. security_invoker keeps the caller's RLS in force.
create view public.reference_names_used with (security_invoker = true) as
  select r.* from public.reference_names r
   where r.name_key in (
     select name_key from public.source_records
     union select name_key from public.accessions
     union select name_key from public.wib_appearances
     union select name_key from public.taxa
   );
grant select on public.reference_names_used to authenticated;
revoke all on public.reference_names_used from anon;

-- -------------------------------------------------- suggest_reference_names
-- "Did you mean" for a name that matched nothing, answered by the database
-- so the browser never downloads the catalogue. Ordered by trigram
-- similarity; 0.3 is pg_trgm's default threshold and keeps nonsense out.
create or replace function public.suggest_reference_names(q text, n int default 5)
  returns table (source text, plant_name text, url text, similarity real)
  language sql stable security invoker set search_path = ''
as $$
  select r.source, r.plant_name, r.url, extensions.similarity(r.plant_name, q) as similarity
    from public.reference_names r
   where public.is_staff()
     and extensions.similarity(r.plant_name, q) > 0.3
   order by similarity desc, r.plant_name
   limit least(greatest(coalesce(n, 5), 1), 25)
$$;
revoke execute on function public.suggest_reference_names(text, int) from anon;
grant execute on function public.suggest_reference_names(text, int) to authenticated;

commit;

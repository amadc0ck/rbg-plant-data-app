-- 006_soil_needs.sql -- soil on the curated record.
-- Applied 2026-09-18 via `supabase db query --linked --project-ref ...`.
--
-- WHY IT WASN'T THERE: the curated fields came from what What's in Bloom
-- publishes, and those PDFs give sun, size and hardiness but never soil.
--
-- WHERE THE VALUES COME FROM: no nursery publishes a soil field either, but
-- San Marcos Growers states it in a sentence on nearly every plant -- "Plant
-- in full sun in a well-drained soil and irrigate occasionally", "Tolerates
-- most soils so long as they are not water-logged", "does particularly well
-- in clay soils". 1,563 of the 6,466 catalogue entries say something usable.
-- The app reads that sentence out of facts.description, offers the matching
-- picklist value, and shows the sentence underneath so a curator can see
-- exactly what the suggestion was built from.
--
-- The values are deliberately few and about DRAINAGE, which is what kills a
-- succulent collection; texture words (sandy, gritty, granitic) collapse into
-- one option rather than becoming a soil-science vocabulary nobody maintains.

begin;

alter table public.taxa add column soil_needs text;

alter table public.list_options drop constraint list_options_list_check;
alter table public.list_options
  add constraint list_options_list_check
  check (list in ('plant_type', 'light_needs', 'water_needs', 'blooming_season', 'soil_needs'));

insert into public.list_options (list, value, sort) values
  ('soil_needs', 'Well-drained', 1),
  ('soil_needs', 'Sandy / gritty', 2),
  ('soil_needs', 'Tolerates most soils', 3),
  ('soil_needs', 'Clay tolerant', 4),
  ('soil_needs', 'Moist / rich', 5)
on conflict (list, value) do nothing;

commit;

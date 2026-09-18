-- 008_wib_card_facts.sql -- the facts printed on each What's in Bloom card.
-- Applied 2026-09-18 via `supabase db query --linked --project-ref ...`.
--
-- WHAT CHANGED: until now the monthly PDFs were read for plant NAMES only,
-- and the facts (native to / form & size / sun / hardy to) came from a
-- hand-kept reference sheet covering about 600 of ~1,260 plants. The PDFs
-- have carried those facts all along, printed under each name in a fixed
-- five-column grid -- the old reader just couldn't pair them, because the
-- text stream runs names and facts in separate groups.
--
-- The new reader uses position and bold styling (pdftohtml -xml), so a card
-- is a bold name plus the non-bold lines beneath it in the same column.
-- That makes the facts PER EDITION, which is why they live here and not on
-- the plant: a plant listed in 2019 and again in 2026 may be described
-- differently, and both are true of their own month.
--
-- extra_note holds what the card prints before the origin line -- a common
-- name, a synonym in parentheses, "California native" -- which is real
-- content that fits none of the four fields.
--
-- card_letter is the A-U key that ties the card to the map on page 2.
-- Keeping it means a future map view can place a plant without re-reading
-- the PDF.
--
-- NOT A CORRECTION: the hand-kept reference sheet stays exactly where it is
-- in source_records. The app shows both and lets a curator choose, which is
-- what she asked for -- the sheet is someone's considered wording, and the
-- PDF is what was actually published that month.

begin;

alter table public.wib_appearances
  add column native_to   text,
  add column form_size   text,
  add column sun_shade   text,
  add column hardy_to    text,
  add column extra_note  text,
  add column card_letter text;

-- Cards whose facts were read from the page, for "how much of the archive
-- has real facts now" without scanning every row.
create index wib_appearances_with_facts on public.wib_appearances (edition_id)
  where native_to is not null or form_size is not null or sun_shade is not null or hardy_to is not null;

commit;

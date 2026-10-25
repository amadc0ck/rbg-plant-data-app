-- 011_main_photo.sql -- the photo a curator picks to represent a plant.
--
-- On taxa (the curated record) rather than a table of its own so a merge
-- carries it along: name_merges_move_taxon already moves the taxon row to
-- the canonical name, and the choice goes with it. It is a URL to a photo
-- the garden already published (Tumblr, Plant Highlight; uploads later),
-- never a copy. Logged by the existing taxa_log trigger.

alter table public.taxa add column main_photo_url text;

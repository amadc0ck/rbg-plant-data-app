-- 003_content_hash.sql -- applied 2026-09-12 via `supabase db query --linked`.
-- The bot used to upsert every source record on every run, re-stamping
-- synced_at on all ~5,000 rows. The app syncs by that stamp, so each bot run
-- forced every open browser into a full ~1 MB re-download even when nothing
-- had changed. The bot now stores an md5 of each record's content here and
-- only writes rows whose hash differs, so synced_at moves only on real change.
-- NULL for irisbg rows (written by the app's import, which replaces them).
alter table public.source_records add column content_hash text;

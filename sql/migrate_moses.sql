-- Moses Hebrew FTS Migration
-- Replaces the naive 'simple' + regex prefix stripping with proper Hebrew lemmatization.
-- Prerequisites: hebrew_fts schema must be installed (001_schema.sql, 002_functions.sql, 004_data.sql)

-- Kill other connections so ALTER TABLE doesn't hang waiting for locks
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = current_database() AND pid != pg_backend_pid();

-- 1. Drop existing index
DROP INDEX IF EXISTS idx_chunks_content_tsv;

-- 2. Drop existing trigger/function (rerunnable migration)
DROP TRIGGER IF EXISTS trg_chunks_content_tsv ON chunks;
DROP FUNCTION IF EXISTS public.update_content_tsv();

-- 3. Drop the old generated column
ALTER TABLE chunks DROP COLUMN IF EXISTS content_tsv;

-- 4. Add new column (plain, not generated — because our functions are STABLE not IMMUTABLE)
ALTER TABLE chunks ADD COLUMN content_tsv tsvector;

-- 5. Create trigger to auto-update on insert/update
CREATE OR REPLACE FUNCTION public.update_content_tsv() RETURNS trigger AS $$
BEGIN
    NEW.content_tsv := hebrew_fts.to_tsvector(coalesce(NEW.content, ''));
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_chunks_content_tsv
    BEFORE INSERT OR UPDATE OF content ON chunks
    FOR EACH ROW
    EXECUTE FUNCTION public.update_content_tsv();

-- 6. Backfill existing rows
-- For large tables (1M+), consider batching — see MOSES_MIGRATION.md
UPDATE chunks SET content_tsv = hebrew_fts.to_tsvector(coalesce(content, ''));

-- 7. Recreate the GIN index
CREATE INDEX idx_chunks_content_tsv ON chunks USING gin (content_tsv);

-- 8. Update statistics
ANALYZE chunks;

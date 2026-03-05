-- Moses Hebrew FTS Migration
-- Replaces the naive 'simple' + regex prefix stripping with proper Hebrew lemmatization.
-- Prerequisites: hebrew_fts schema must be installed (001_schema.sql, 002_functions.sql, 004_data.sql)

-- 1. Drop existing index
DROP INDEX IF EXISTS idx_chunks_content_tsv;

-- 2. Drop the old generated column
ALTER TABLE chunks DROP COLUMN IF EXISTS content_tsv;

-- 3. Add new column (plain, not generated — because our functions are STABLE not IMMUTABLE)
ALTER TABLE chunks ADD COLUMN content_tsv tsvector;

-- 4. Create trigger to auto-update on insert/update
CREATE OR REPLACE FUNCTION update_content_tsv() RETURNS trigger AS $$
BEGIN
    NEW.content_tsv := hebrew_fts.to_tsvector(coalesce(NEW.content, ''));
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_chunks_content_tsv
    BEFORE INSERT OR UPDATE OF content ON chunks
    FOR EACH ROW
    EXECUTE FUNCTION update_content_tsv();

-- 5. Backfill existing rows
-- For large tables (1M+), consider batching — see MOSES_MIGRATION.md
UPDATE chunks SET content_tsv = hebrew_fts.to_tsvector(coalesce(content, ''));

-- 6. Recreate the GIN index
CREATE INDEX idx_chunks_content_tsv ON chunks USING gin (content_tsv);

-- 7. Update statistics
ANALYZE chunks;

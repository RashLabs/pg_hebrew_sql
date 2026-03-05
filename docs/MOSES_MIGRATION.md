# Moses Hebrew FTS Migration Guide

## How FTS Works in Moses Today

### Architecture
Moses uses a **hybrid search** system combining:
1. **Semantic search** — vector embeddings (Qdrant/pgvector) for meaning-based retrieval
2. **Lexical search** — PostgreSQL full-text search (tsvector/GIN) for exact keyword matching
3. **Hybrid mode** — weighted combination of both (configurable weights)

### Current Lexical Search Flow

```
User query → websearch_to_tsquery('simple', query)
                         ↓
              chunks.content_tsv (GIN index)
                         ↓
              ts_rank_cd() for scoring
                         ↓
              ts_headline() for snippet highlighting
```

### The `chunks` Table
Every document uploaded to Moses gets split into chunks. Each chunk has:
- `content` — the actual text
- `content_tsv` — a **generated tsvector column** (auto-computed from content)
- A **GIN index** on `content_tsv` for fast full-text search

### Current tsvector Generation (The Problem)

The current column definition (from `update_chunks_lexical_normalization.sql`):

```sql
ALTER TABLE chunks
    ADD COLUMN content_tsv tsvector
        GENERATED ALWAYS AS (
            to_tsvector('simple', coalesce(content, '')) ||
            to_tsvector(
                'simple',
                regexp_replace(
                    coalesce(content, ''),
                    '\m[הוכלמש]{1,3}(?=[א-ת]{2,})',
                    '',
                    'g'
                )
            )
        )
        STORED;
```

This does two things:
1. Creates a tsvector from the **raw content** (using `'simple'` config — just lowercases, no analysis)
2. Creates a SECOND tsvector from content with **regex prefix stripping** — blindly removes 1-3 chars from `[הוכלמש]` before Hebrew words
3. **Concatenates both** so you match with or without prefixes

### What's Wrong With This

| Problem | Example | Impact |
|---------|---------|--------|
| **No lemmatization** | "חוזה" (contract) and "חוזים" (contracts) don't match | Misses plural/conjugated forms |
| **Naive prefix stripping** | "שלום" (peace) → strips "ש" → "לום" (nonsense) | False positives, corrupted index |
| **No stop word filtering** | "של", "על", "את" get indexed | Bloated index, noise in ranking |
| **No morphological awareness** | "הלקוח" could be "ה+לקוח" or the word "הלקוח" itself | Regex can't distinguish |
| **Double tsvector = double index size** | Every chunk stores 2 tsvectors concatenated | Wasted storage + slower writes |

### Where Lexical Search Is Used

1. **`postgres_vector_store.py`** → `search_chunks_lexical()` — core lexical search method
2. **`project_doc_search_service.py`** → hybrid ranking (semantic + lexical scores), snippet highlighting via `ts_headline()`
3. **`retriever_tool.py`** → Agent mode `lexical_search` tool — the AI agent can run lexical queries

All three use `websearch_to_tsquery('simple', query_text)` for query parsing.

---

## What pg_hebrew_sql Fixes

| Before (simple + regex) | After (pg_hebrew_sql) |
|---|---|
| "חוזים" ≠ "חוזה" | "חוזים" → lemma "חוזה" ✅ |
| "הלקוח" → regex strips "ה" blindly | "הלקוח" → validates prefix, returns "לקוח" ✅ |
| "של" indexed as a token | "של" filtered as stop word ✅ |
| "שלום" → "לום" (broken) | "שלום" → "שלום" (recognized word, no stripping) ✅ |
| Double tsvector per chunk | Single tsvector, proper lemmas ✅ |

---

## Migration Steps

### Step 1: Install pg_hebrew_sql on RDS

```bash
# Generate the data file (run once on your local machine)
cd pg_hebrew_sql
python3 scripts/extract_hspell_data.py

# Upload and run on RDS
psql -h your-rds-host -U your-user -d moses_db -f sql/001_schema.sql
psql -h your-rds-host -U your-user -d moses_db -f sql/002_functions.sql
psql -h your-rds-host -U your-user -d moses_db -f sql/004_data.sql  # ~24MB, takes 1-2 min
```

### Step 2: Run the migration SQL

```sql
-- File: backend/migrations/migrate_hebrew_fts.sql

-- 1. Drop existing index
DROP INDEX IF EXISTS idx_chunks_content_tsv;

-- 2. Drop the old generated column
ALTER TABLE chunks DROP COLUMN IF EXISTS content_tsv;

-- 3. Add new column using hebrew_fts.to_tsvector
--    NOTE: Generated columns can't call non-IMMUTABLE functions.
--    hebrew_fts.lexize() is STABLE (reads tables), so we use a trigger instead.

ALTER TABLE chunks ADD COLUMN content_tsv tsvector;

-- 4. Create the trigger function
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

-- 5. Backfill existing rows (this is the slow part — depends on table size)
UPDATE chunks SET content_tsv = hebrew_fts.to_tsvector(coalesce(content, ''));

-- 6. Recreate the GIN index
CREATE INDEX idx_chunks_content_tsv ON chunks USING gin (content_tsv);

-- 7. Analyze for query planner
ANALYZE chunks;
```

> ⏱️ **Estimated time:** The backfill (`UPDATE chunks SET ...`) depends on row count.
> For 100K chunks, expect ~5-10 minutes. For 1M+ chunks, consider batching
> (see "Large Table Migration" below).

### Step 3: Update Python code

**`postgres_vector_store.py`** — change query parsing:

```python
# BEFORE:
"ts_rank_cd(content_tsv, websearch_to_tsquery('simple', :query_text)) as rank"
# ...
"WHERE content_tsv @@ websearch_to_tsquery('simple', :query_text)"

# AFTER:
"ts_rank_cd(content_tsv, hebrew_fts.to_tsquery(:query_text)) as rank"
# ...
"WHERE content_tsv @@ hebrew_fts.to_tsquery(:query_text)"
```

**`project_doc_search_service.py`** — change headline generation:

```python
# BEFORE:
"ts_headline('simple', content, websearch_to_tsquery('simple', :query_text), ...)"

# AFTER:
"ts_headline('simple', content, hebrew_fts.to_tsquery(:query_text), ...)"
```

> Note: `ts_headline` still uses `'simple'` for the first argument — that controls
> how it *displays* the text (highlighting), not how it searches. The tsquery from
> `hebrew_fts.to_tsquery()` handles the Hebrew-aware matching.

### Step 4: Verify

```sql
-- Test basic functionality
SELECT hebrew_fts.lexize('בחוזה');     -- Should return {חוזה}
SELECT hebrew_fts.lexize('הלקוחות');   -- Should return lemmas including לקוח

-- Test on actual chunks
SELECT id, ts_rank_cd(content_tsv, hebrew_fts.to_tsquery('חוזה לקוח')) as rank
FROM chunks
WHERE content_tsv @@ hebrew_fts.to_tsquery('חוזה לקוח')
ORDER BY rank DESC
LIMIT 5;

-- Compare old vs new (run BEFORE dropping old column)
SELECT
    id,
    ts_rank_cd(content_tsv, websearch_to_tsquery('simple', 'חוזים')) as old_rank,
    ts_rank_cd(hebrew_fts.to_tsvector(content), hebrew_fts.to_tsquery('חוזים')) as new_rank
FROM chunks
WHERE content LIKE '%חוז%'
LIMIT 10;
```

---

## Large Table Migration (1M+ chunks)

If you have many chunks, batch the backfill to avoid locking:

```sql
-- Batch update in groups of 10,000
DO $$
DECLARE
    batch_size INT := 10000;
    updated INT;
BEGIN
    LOOP
        UPDATE chunks
        SET content_tsv = hebrew_fts.to_tsvector(coalesce(content, ''))
        WHERE id IN (
            SELECT id FROM chunks
            WHERE content_tsv IS NULL
            LIMIT batch_size
        );
        GET DIAGNOSTICS updated = ROW_COUNT;
        RAISE NOTICE 'Updated % rows', updated;
        IF updated = 0 THEN EXIT; END IF;
        PERFORM pg_sleep(0.5);  -- breathe between batches
    END LOOP;
END $$;
```

---

## Rollback Plan

If something goes wrong, revert to the old approach:

```sql
-- Drop new trigger
DROP TRIGGER IF EXISTS trg_chunks_content_tsv ON chunks;
DROP FUNCTION IF EXISTS update_content_tsv();

-- Drop and recreate old column
DROP INDEX IF EXISTS idx_chunks_content_tsv;
ALTER TABLE chunks DROP COLUMN IF EXISTS content_tsv;

ALTER TABLE chunks
    ADD COLUMN content_tsv tsvector
        GENERATED ALWAYS AS (
            to_tsvector('simple', coalesce(content, '')) ||
            to_tsvector('simple', regexp_replace(coalesce(content, ''), '\m[הוכלמש]{1,3}(?=[א-ת]{2,})', '', 'g'))
        ) STORED;

CREATE INDEX idx_chunks_content_tsv ON chunks USING gin (content_tsv);
```

And revert the Python changes (tsquery back to `websearch_to_tsquery('simple', ...)`).

---

## Performance Notes

- **Index size** will likely *decrease* — one tsvector with proper lemmas vs. two concatenated tsvectors with raw + stripped tokens
- **Query quality** will dramatically improve — proper morphological matching means fewer false positives/negatives
- **Write overhead** is slightly higher per-row (lexize does table lookups) but the trigger is fast — dictionary table has a PRIMARY KEY index, lookups are O(1)
- **Consider:** Adding a hash index on `hebrew_fts.dictionary.word` if you see slow lexize performance at scale (the PRIMARY KEY B-tree should be fine though)

---

## Files Changed Summary

| File | Change |
|---|---|
| `sql/migrate_hebrew_fts.sql` | New migration (schema + trigger + backfill) |
| `postgres_vector_store.py` | `websearch_to_tsquery('simple', ...)` → `hebrew_fts.to_tsquery(...)` |
| `project_doc_search_service.py` | Same tsquery change + ts_headline update |
| `retriever_tool.py` | No changes needed (calls `search_chunks_lexical` which handles it) |

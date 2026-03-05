# pg_hebrew_sql

Pure PL/pgSQL Hebrew full-text search for PostgreSQL. **Works on AWS RDS** — no C extensions needed.

Ported from [pg_hebrew](https://github.com/RashLabs/pg_hebrew) (Rust/pgrx).

## Features

- Hebrew lemmatization (morphological analysis via Hspell dictionary)
- Hebrew prefix stripping (ב, ל, מ, ש, ו, כ, ה and combinations)
- Niqqud (vowel marks) removal
- Hebrew stop words
- `to_tsvector` / `to_tsquery` for full-text search

## Installation

### On RDS or any PostgreSQL 14+

```bash
# 1. Generate data (only needed once, already included in sql/004_data.sql)
python3 scripts/extract_hspell_data.py

# 2. Install
psql -h your-host -U your-user -d your-db -f sql/install.sql
```

### Quick test

```sql
SELECT hebrew_fts.lexize('בחוזה');       -- {חוזה}
SELECT hebrew_fts.lexize('הלקוח');       -- {לקוח}
SELECT hebrew_fts.remove_niqqud('שָׁלוֹם'); -- שלום
SELECT hebrew_fts.is_stop_word('של');     -- true

SELECT hebrew_fts.to_tsvector('הלקוח חתם על החוזה');
```

## Schema

All objects live in the `hebrew_fts` schema:

- `hebrew_fts.dictionary` — 338K Hebrew words from Hspell
- `hebrew_fts.lemmas` — word→lemma mappings with morphological flags
- `hebrew_fts.prefixes` — valid Hebrew prefix combinations
- `hebrew_fts.stop_words` — common Hebrew stop words

## License

AGPL-3.0 (same as pg_hebrew)

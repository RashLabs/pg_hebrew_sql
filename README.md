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

1. Place the Hspell source files under `pg_hebrew_sql/hspell-data/` (or pass `--hspell-dir`).

2. Generate `sql/004_data.sql`:

```powershell
Set-Location "C:\dev\MosesLabs\pg_hebrew_sql"
python ".\scripts\extract_hspell_data.py"
```

3. Install:

```powershell
$env:PGPASSWORD="your-password"; psql -h 127.0.0.1 -U your-user -d your-db -v ON_ERROR_STOP=1 -f ".\sql\install.sql"
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

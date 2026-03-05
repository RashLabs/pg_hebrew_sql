-- pg_hebrew_sql schema
CREATE SCHEMA IF NOT EXISTS hebrew_fts;

CREATE TABLE hebrew_fts.dictionary (
    word TEXT PRIMARY KEY,
    prefixes SMALLINT NOT NULL DEFAULT 0
);

CREATE TABLE hebrew_fts.lemmas (
    word TEXT NOT NULL,
    lemma TEXT NOT NULL,
    desc_flag SMALLINT NOT NULL DEFAULT 0,
    prefix_type SMALLINT NOT NULL DEFAULT 0
);
CREATE INDEX idx_lemmas_word ON hebrew_fts.lemmas (word);

CREATE TABLE hebrew_fts.prefixes (
    prefix TEXT PRIMARY KEY,
    mask INTEGER NOT NULL
);

CREATE TABLE hebrew_fts.stop_words (
    word TEXT PRIMARY KEY
);

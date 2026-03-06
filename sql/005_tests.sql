-- pg_hebrew_sql tests
-- Run with: psql -d moses_one -f sql/005_tests.sql

DO $$
DECLARE
    result TEXT[];
    txt TEXT;
    ok BOOLEAN;
BEGIN
    -- Test 1: remove_niqqud
    txt := hebrew_fts.remove_niqqud('שָׁלוֹם');
    ASSERT txt = 'שלום', 'remove_niqqud failed: ' || txt;
    RAISE NOTICE 'PASS: remove_niqqud';

    -- Test 2: is_stop_word
    ok := hebrew_fts.is_stop_word('על');
    ASSERT ok, 'is_stop_word(על) should be true';
    ok := hebrew_fts.is_stop_word('חוזה');
    ASSERT NOT ok, 'is_stop_word(חוזה) should be false';
    RAISE NOTICE 'PASS: is_stop_word';

    -- Test 3: lexize basic
    result := hebrew_fts.lexize('חוזה');
    ASSERT array_length(result, 1) > 0, 'חוזה should return lemmas';
    RAISE NOTICE 'PASS: lexize(חוזה) = %', result;

    -- Test 4: lexize prefix ה
    result := hebrew_fts.lexize('הלקוח');
    ASSERT 'לקוח' = ANY(result), 'הלקוח should include לקוח, got: ' || result::text;
    RAISE NOTICE 'PASS: lexize(הלקוח) = %', result;

    -- Test 5: lexize stop word
    result := hebrew_fts.lexize('של');
    ASSERT array_length(result, 1) IS NULL OR array_length(result, 1) = 0,
        'של should return empty, got: ' || coalesce(result::text, 'NULL');
    RAISE NOTICE 'PASS: lexize(של) = empty';

    -- Test 6: lexize prefix ב
    result := hebrew_fts.lexize('בחוזה');
    ASSERT 'חוזה' = ANY(result), 'בחוזה should include חוזה, got: ' || result::text;
    RAISE NOTICE 'PASS: lexize(בחוזה) = %', result;

    -- Test 7: unknown word
    result := hebrew_fts.lexize('xyznonexistent');
    ASSERT result = ARRAY['xyznonexistent'], 'unknown should return as-is, got: ' || result::text;
    RAISE NOTICE 'PASS: lexize(xyznonexistent) = %', result;

    -- Test 8: websearch_to_tsquery basic AND
    DECLARE
        q tsquery;
    BEGIN
        q := hebrew_fts.websearch_to_tsquery('חוזה שכירות');
        ASSERT q IS NOT NULL AND q::text != '', 'websearch_to_tsquery AND failed: ' || coalesce(q::text, 'NULL');
        RAISE NOTICE 'PASS: websearch_to_tsquery AND = %', q;
    END;

    -- Test 9: websearch_to_tsquery OR
    DECLARE
        q tsquery;
    BEGIN
        q := hebrew_fts.websearch_to_tsquery('חוזה OR הסכם');
        ASSERT q IS NOT NULL AND q::text != '', 'websearch_to_tsquery OR failed';
        -- Should contain | operator
        ASSERT position('|' in q::text) > 0, 'websearch_to_tsquery OR should contain |, got: ' || q::text;
        RAISE NOTICE 'PASS: websearch_to_tsquery OR = %', q;
    END;

    -- Test 10: websearch_to_tsquery negation
    DECLARE
        q tsquery;
    BEGIN
        q := hebrew_fts.websearch_to_tsquery('חוזה -טיוטה');
        ASSERT q IS NOT NULL AND q::text != '', 'websearch_to_tsquery negation failed';
        ASSERT position('!' in q::text) > 0, 'websearch_to_tsquery negation should contain !, got: ' || q::text;
        RAISE NOTICE 'PASS: websearch_to_tsquery negation = %', q;
    END;

    -- Test 11: websearch_to_tsquery phrase
    DECLARE
        q tsquery;
    BEGIN
        q := hebrew_fts.websearch_to_tsquery('"חוזה שכירות"');
        ASSERT q IS NOT NULL AND q::text != '', 'websearch_to_tsquery phrase failed';
        ASSERT position('<->' in q::text) > 0, 'websearch_to_tsquery phrase should contain <->, got: ' || q::text;
        RAISE NOTICE 'PASS: websearch_to_tsquery phrase = %', q;
    END;

    -- Test 12: websearch_to_tsquery empty input
    DECLARE
        q tsquery;
    BEGIN
        q := hebrew_fts.websearch_to_tsquery('');
        ASSERT q::text = '', 'websearch_to_tsquery empty should return empty, got: ' || q::text;
        RAISE NOTICE 'PASS: websearch_to_tsquery empty';
    END;

    RAISE NOTICE '✅ All tests passed!';
END;
$$;

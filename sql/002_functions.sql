-- pg_hebrew_sql functions

-- Remove niqqud (Hebrew vowel/cantillation marks)
CREATE OR REPLACE FUNCTION hebrew_fts.remove_niqqud(input TEXT)
RETURNS TEXT AS $$
BEGIN
    -- Remove Unicode ranges: U+0591-U+05BD, U+05BF, U+05C1-U+05C2, U+05C4-U+05C5, U+05C7
    RETURN regexp_replace(input, '[\u0591-\u05BD\u05BF\u05C1\u05C2\u05C4\u05C5\u05C7]', '', 'g');
END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;

-- Check if a word is a stop word
CREATE OR REPLACE FUNCTION hebrew_fts.is_stop_word(w TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN EXISTS (SELECT 1 FROM hebrew_fts.stop_words WHERE word = w);
END;
$$ LANGUAGE plpgsql STABLE STRICT;

-- Check if a string is a legal Hebrew prefix
CREATE OR REPLACE FUNCTION hebrew_fts.is_legal_prefix(p TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    IF p = '' THEN RETURN TRUE; END IF;
    RETURN EXISTS (SELECT 1 FROM hebrew_fts.prefixes WHERE prefix = p);
END;
$$ LANGUAGE plpgsql STABLE STRICT;

-- Get prefix mask
CREATE OR REPLACE FUNCTION hebrew_fts.get_prefix_mask(p TEXT)
RETURNS INTEGER AS $$
DECLARE
    m INTEGER;
BEGIN
    SELECT mask INTO m FROM hebrew_fts.prefixes WHERE prefix = p;
    RETURN m;
END;
$$ LANGUAGE plpgsql STABLE STRICT;

-- Try stripping prefix before quote characters (gershayim/geresh)
CREATE OR REPLACE FUNCTION hebrew_fts.try_strip_prefix_quote(w TEXT)
RETURNS TEXT AS $$
DECLARE
    chars TEXT[];
    i INTEGER;
    prefix_str TEXT;
    c TEXT;
BEGIN
    -- Convert to array of characters
    chars := regexp_split_to_array(w, '');
    
    -- Check for double-quote (gershayim)
    FOR i IN 1..array_length(chars, 1) LOOP
        c := chars[i];
        IF c = '"' OR c = E'\u05F4' THEN
            IF i > 1 AND i < array_length(chars, 1) - 1 THEN
                prefix_str := array_to_string(chars[1:i-1], '');
                IF hebrew_fts.is_legal_prefix(prefix_str) THEN
                    RETURN array_to_string(chars[i+1:], '');
                END IF;
            END IF;
            EXIT;
        END IF;
    END LOOP;
    
    -- Check for single-quote (geresh)
    FOR i IN 1..array_length(chars, 1) LOOP
        c := chars[i];
        IF c = '''' OR c = E'\u05F3' THEN
            IF i > 1 THEN
                prefix_str := array_to_string(chars[1:i-1], '');
                IF hebrew_fts.is_legal_prefix(prefix_str) THEN
                    RETURN array_to_string(chars[i+1:], '');
                END IF;
            END IF;
            EXIT;
        END IF;
    END LOOP;
    
    RETURN w;
END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;

-- Main lexize function
CREATE OR REPLACE FUNCTION hebrew_fts.lexize(token TEXT)
RETURNS TEXT[] AS $$
DECLARE
    clean TEXT;
    result TEXT[] := '{}';
    chars TEXT[];
    pref_len INTEGER;
    prefix_str TEXT;
    remainder TEXT;
    prefix_mask INTEGER;
    word_prefixes SMALLINT;
    rec RECORD;
    last_char TEXT;
    stripped TEXT;
BEGIN
    -- Clean niqqud
    clean := hebrew_fts.remove_niqqud(token);
    
    -- Try stripping prefix before quotes
    clean := hebrew_fts.try_strip_prefix_quote(clean);
    
    -- Check stop words
    IF hebrew_fts.is_stop_word(clean) THEN
        RETURN '{}';
    END IF;
    
    -- 1. Direct dictionary lookup
    SELECT array_agg(DISTINCT l.lemma) INTO result
    FROM hebrew_fts.lemmas l
    WHERE l.word = clean;
    
    IF result IS NOT NULL AND array_length(result, 1) > 0 THEN
        RETURN result;
    END IF;
    
    -- 2. Try omitting closing geresh
    last_char := right(clean, 1);
    IF last_char = '''' OR last_char = E'\u05F3' THEN
        stripped := left(clean, length(clean) - 1);
        SELECT array_agg(DISTINCT l.lemma) INTO result
        FROM hebrew_fts.lemmas l
        WHERE l.word = stripped;
        
        IF result IS NOT NULL AND array_length(result, 1) > 0 THEN
            RETURN result;
        END IF;
    END IF;
    
    -- 3. Try prefix stripping
    result := '{}';
    chars := regexp_split_to_array(clean, '');
    pref_len := 0;
    
    LOOP
        -- Need at least 2 chars remaining
        IF array_length(chars, 1) - pref_len < 2 THEN
            EXIT;
        END IF;
        
        pref_len := pref_len + 1;
        prefix_str := array_to_string(chars[1:pref_len], '');
        
        -- Check if valid prefix
        prefix_mask := hebrew_fts.get_prefix_mask(prefix_str);
        IF prefix_mask IS NULL THEN
            EXIT;
        END IF;
        
        remainder := array_to_string(chars[pref_len+1:], '');
        
        -- Look up remainder in dictionary with prefix validation
        FOR rec IN
            SELECT DISTINCT l.lemma
            FROM hebrew_fts.lemmas l
            JOIN hebrew_fts.dictionary d ON d.word = l.word
            WHERE l.word = remainder
              AND (d.prefixes::integer & prefix_mask) > 0
              AND (l.prefix_type::integer & prefix_mask) > 0
        LOOP
            result := array_append(result, rec.lemma);
        END LOOP;
    END LOOP;
    
    IF array_length(result, 1) > 0 THEN
        RETURN result;
    END IF;
    
    -- 4. Unknown word - return cleaned token
    RETURN ARRAY[clean];
END;
$$ LANGUAGE plpgsql STABLE STRICT;

-- Convenience: Hebrew to_tsvector using our lexizer
CREATE OR REPLACE FUNCTION hebrew_fts.to_tsvector(input TEXT)
RETURNS tsvector AS $$
DECLARE
    words TEXT[];
    w TEXT;
    lemmas TEXT[];
    lemma TEXT;
    result tsvector := ''::tsvector;
    pos INTEGER := 0;
BEGIN
    -- Simple tokenization: split on non-Hebrew, non-alphanumeric
    words := regexp_split_to_array(lower(input), '[^א-תa-z0-9''"]+');
    
    FOREACH w IN ARRAY words LOOP
        IF w = '' THEN CONTINUE; END IF;
        pos := pos + 1;
        lemmas := hebrew_fts.lexize(w);
        IF lemmas IS NOT NULL THEN
            FOREACH lemma IN ARRAY lemmas LOOP
                IF lemma IS NOT NULL AND lemma != '' THEN
                    result := result || setweight(to_tsvector('simple', lemma), 'D');
                END IF;
            END LOOP;
        END IF;
    END LOOP;
    
    RETURN result;
END;
$$ LANGUAGE plpgsql STABLE STRICT;

-- Convenience: Hebrew to_tsquery
CREATE OR REPLACE FUNCTION hebrew_fts.to_tsquery(input TEXT)
RETURNS tsquery AS $$
DECLARE
    words TEXT[];
    w TEXT;
    lemmas TEXT[];
    parts TEXT[] := '{}';
BEGIN
    words := regexp_split_to_array(lower(input), '[^א-תa-z0-9''"]+');
    
    FOREACH w IN ARRAY words LOOP
        IF w = '' THEN CONTINUE; END IF;
        lemmas := hebrew_fts.lexize(w);
        IF lemmas IS NOT NULL AND array_length(lemmas, 1) > 0 THEN
            IF array_length(lemmas, 1) = 1 THEN
                parts := array_append(parts, '''' || replace(lemmas[1], '''', '''''') || '''');
            ELSE
                parts := array_append(parts, '(' || array_to_string(
                    (SELECT array_agg('''' || replace(l, '''', '''''') || '''') FROM unnest(lemmas) AS l), ' | '
                ) || ')');
            END IF;
        END IF;
    END LOOP;
    
    IF array_length(parts, 1) > 0 THEN
        RETURN (array_to_string(parts, ' & '))::tsquery;
    END IF;
    
    RETURN ''::tsquery;
END;
$$ LANGUAGE plpgsql STABLE STRICT;

-- Websearch-style query parser with Hebrew morphology
-- Supports: "exact phrase", OR, -negation, implicit AND
CREATE OR REPLACE FUNCTION hebrew_fts.websearch_to_tsquery(input TEXT)
RETURNS tsquery AS $$
DECLARE
    raw TEXT;
    pos INTEGER := 1;
    len INTEGER;
    ch TEXT;
    token TEXT;
    token_lemmas TEXT[];
    parts TEXT[] := '{}';        -- top-level parts joined by &
    phrase_parts TEXT[] := '{}'; -- phrase lemmas joined by <->
    negate BOOLEAN := FALSE;
    next_or BOOLEAN := FALSE;
    part TEXT;
    lemma_expr TEXT;
    result tsquery;
BEGIN
    raw := trim(input);
    IF raw = '' OR raw IS NULL THEN
        RETURN ''::tsquery;
    END IF;
    len := length(raw);

    WHILE pos <= len LOOP
        ch := substring(raw FROM pos FOR 1);

        -- Skip whitespace
        IF ch = ' ' OR ch = E'\t' OR ch = E'\n' OR ch = E'\r' THEN
            pos := pos + 1;
            CONTINUE;
        END IF;

        -- Quoted phrase
        IF ch = '"' THEN
            pos := pos + 1;
            phrase_parts := '{}';
            WHILE pos <= len LOOP
                ch := substring(raw FROM pos FOR 1);
                IF ch = '"' THEN
                    pos := pos + 1;
                    EXIT;
                END IF;
                -- Collect word inside phrase
                IF ch = ' ' OR ch = E'\t' THEN
                    pos := pos + 1;
                    CONTINUE;
                END IF;
                token := '';
                WHILE pos <= len LOOP
                    ch := substring(raw FROM pos FOR 1);
                    IF ch = '"' OR ch = ' ' OR ch = E'\t' THEN EXIT; END IF;
                    token := token || ch;
                    pos := pos + 1;
                END LOOP;
                IF token != '' THEN
                    token_lemmas := hebrew_fts.lexize(lower(token));
                    IF token_lemmas IS NOT NULL AND array_length(token_lemmas, 1) > 0 THEN
                        IF array_length(token_lemmas, 1) = 1 THEN
                            phrase_parts := array_append(phrase_parts,
                                '''' || replace(token_lemmas[1], '''', '''''') || '''');
                        ELSE
                            phrase_parts := array_append(phrase_parts,
                                '(' || array_to_string(
                                    (SELECT array_agg('''' || replace(l, '''', '''''') || '''')
                                     FROM unnest(token_lemmas) AS l), ' | '
                                ) || ')');
                        END IF;
                    END IF;
                END IF;
            END LOOP;
            -- Build phrase with <-> (adjacent) operator
            IF array_length(phrase_parts, 1) > 0 THEN
                part := array_to_string(phrase_parts, ' <-> ');
                IF negate THEN
                    part := '!' || '(' || part || ')';
                    negate := FALSE;
                END IF;
                IF next_or AND array_length(parts, 1) > 0 THEN
                    parts[array_length(parts, 1)] :=
                        parts[array_length(parts, 1)] || ' | ' || part;
                    next_or := FALSE;
                ELSE
                    parts := array_append(parts, part);
                    next_or := FALSE;
                END IF;
            END IF;
            CONTINUE;
        END IF;

        -- Negation prefix
        IF ch = '-' THEN
            negate := TRUE;
            pos := pos + 1;
            CONTINUE;
        END IF;

        -- Collect bare token
        token := '';
        WHILE pos <= len LOOP
            ch := substring(raw FROM pos FOR 1);
            IF ch = ' ' OR ch = E'\t' OR ch = E'\n' OR ch = E'\r' OR ch = '"' THEN EXIT; END IF;
            token := token || ch;
            pos := pos + 1;
        END LOOP;

        -- Check for OR keyword
        IF upper(token) = 'OR' THEN
            next_or := TRUE;
            CONTINUE;
        END IF;

        -- Skip empty tokens
        IF token = '' THEN
            CONTINUE;
        END IF;

        -- Lemmatize token
        token_lemmas := hebrew_fts.lexize(lower(token));
        IF token_lemmas IS NULL OR array_length(token_lemmas, 1) = 0 THEN
            CONTINUE;
        END IF;

        IF array_length(token_lemmas, 1) = 1 THEN
            lemma_expr := '''' || replace(token_lemmas[1], '''', '''''') || '''';
        ELSE
            lemma_expr := '(' || array_to_string(
                (SELECT array_agg('''' || replace(l, '''', '''''') || '''')
                 FROM unnest(token_lemmas) AS l), ' | '
            ) || ')';
        END IF;

        IF negate THEN
            lemma_expr := '!' || lemma_expr;
            negate := FALSE;
        END IF;

        IF next_or AND array_length(parts, 1) > 0 THEN
            parts[array_length(parts, 1)] :=
                parts[array_length(parts, 1)] || ' | ' || lemma_expr;
            next_or := FALSE;
        ELSE
            parts := array_append(parts, lemma_expr);
            next_or := FALSE;
        END IF;
    END LOOP;

    IF array_length(parts, 1) > 0 THEN
        BEGIN
            result := (array_to_string(parts, ' & '))::tsquery;
            RETURN result;
        EXCEPTION WHEN OTHERS THEN
            -- Fall back to plain to_tsquery if parse fails
            RETURN hebrew_fts.to_tsquery(input);
        END;
    END IF;

    RETURN ''::tsquery;
END;
$$ LANGUAGE plpgsql STABLE STRICT;

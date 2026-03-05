#!/usr/bin/env python3
"""Extract hspell binary data into SQL for pg_hebrew_sql."""

import gzip
import os
import sys

HSPELL_DIR = os.path.join(os.path.dirname(__file__), '../../pg_hebrew/hspell-data')
OUTPUT_DIR = os.path.join(os.path.dirname(__file__), '../sql')


def iso8859_to_unicode(b):
    if 0xE0 <= b <= 0xFA:
        return chr(b + 0x4F0)
    elif b <= 0xBE:
        return chr(b)
    return ' '


def parse_dmasks():
    with open(os.path.join(HSPELL_DIR, 'dmask.c'), 'r') as f:
        text = f.read()
    dmasks = []
    in_array = False
    for line in text.split('\n'):
        if 'dmasks[]' in line:
            in_array = True
            continue
        if in_array:
            t = line.strip().rstrip(',').strip()
            if t == '};':
                break
            try:
                dmasks.append(int(t))
            except:
                pass
    return dmasks


def parse_word_count():
    with open(os.path.join(HSPELL_DIR, 'hebrew.wgz.sizes'), 'rb') as f:
        lines = f.read().decode('utf-8').strip().split('\n')
    return int(lines[1].split()[-1]) - 1


def parse_word_list():
    with gzip.open(os.path.join(HSPELL_DIR, 'hebrew.wgz'), 'rb') as f:
        wgz = f.read()
    lookup = []
    sbuf = bytearray(64)
    slen = 0
    pos = 0
    while pos < len(wgz):
        c = wgz[pos]; pos += 1
        if ord('0') <= c <= ord('9'):
            word = ''.join(iso8859_to_unicode(sbuf[i]) for i in range(slen))
            lookup.append(word)
            n = c - ord('0')
            while pos < len(wgz):
                nc = wgz[pos]
                if ord('0') <= nc <= ord('9'):
                    n = n * 10 + (nc - ord('0')); pos += 1
                else:
                    break
            slen = max(0, slen - n)
        else:
            if slen < 64:
                sbuf[slen] = c; slen += 1
    if slen > 0:
        lookup.append(''.join(iso8859_to_unicode(sbuf[i]) for i in range(slen)))
    return lookup


def parse_prefixes_file(data):
    result = {}
    decoder = gzip.decompress(data)
    for line in decoder.decode('utf-8', errors='replace').split('\n'):
        line = line.strip()
        if not line:
            continue
        if '#' in line:
            prefix, mask_str = line.split('#', 1)
            try:
                mask = int(mask_str)
                if prefix in result:
                    result[prefix] |= mask
                else:
                    result[prefix] = mask
            except:
                pass
    return result


def parse_all_prefixes():
    with open(os.path.join(HSPELL_DIR, 'prefix_noH.gz'), 'rb') as f:
        no_h = parse_prefixes_file(f.read())
    with open(os.path.join(HSPELL_DIR, 'prefix_h.gz'), 'rb') as f:
        h = parse_prefixes_file(f.read())
    merged = dict(no_h)
    for k, v in h.items():
        if k in merged:
            merged[k] |= v
        else:
            merged[k] = v
    return merged


def read_desc_entries(desc_bytes, pos, dmasks):
    result = []
    while pos < len(desc_bytes):
        b = desc_bytes[pos]
        if b == ord('\n') or b == 0:
            pos += 1; break
        if pos + 1 >= len(desc_bytes):
            pos += 1; break
        b0 = desc_bytes[pos]; b1 = desc_bytes[pos + 1]; pos += 2
        a = ord('A')
        if b0 >= a and b1 >= a:
            idx = (b0 - a) + (b1 - a) * 26
            if idx < len(dmasks):
                result.append(dmasks[idx])
    return result, pos


def read_stem_entries(stem_bytes, pos):
    result = []
    while pos < len(stem_bytes):
        b = stem_bytes[pos]
        if b == ord('\n') or b == 0:
            pos += 1; break
        if pos + 2 >= len(stem_bytes):
            pos = len(stem_bytes); break
        b0 = stem_bytes[pos]; b1 = stem_bytes[pos+1]; b2 = stem_bytes[pos+2]; pos += 3
        val = (b0 - 33) + (b1 - 33) * 94 + (b2 - 33) * 94 * 94
        result.append(val)
    return result, pos


# DMask constants
D_TYPEMASK = 3; D_NOUN = 1; D_VERB = 2; D_ADJ = 3
D_TENSEMASK = 1792; D_INFINITIVE = 256; D_BINFINITIVE = 1536
D_IMPERATIVE = 1280; D_PRESENT = 768
D_OMASK = 129024; D_OSMICHUT = 131072; D_SPECNOUN = 262144


def dmask_to_prefix(dmask_val):
    type_bits = dmask_val & D_TYPEMASK
    tense_bits = dmask_val & D_TENSEMASK
    if type_bits == D_VERB:
        if tense_bits == D_INFINITIVE: return 2  # L
        if tense_bits == D_BINFINITIVE: return 1  # B
        if tense_bits == D_IMPERATIVE: return 16  # Imper
        if tense_bits != D_PRESENT: return 4  # Verb
        if (dmask_val & D_OSMICHUT) > 0 or (dmask_val & D_OMASK) > 0: return 8  # NonDef
        return 127  # All
    if type_bits in (D_NOUN, D_ADJ):
        if (dmask_val & D_OSMICHUT) > 0 or (dmask_val & D_OMASK) > 0 or (dmask_val & D_SPECNOUN) > 0:
            return 8  # NonDef
        return 127  # All
    return 127  # All


def escape_sql(s):
    return s.replace("'", "''")


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    
    print("Parsing dmasks...")
    dmasks = parse_dmasks()
    
    print("Parsing word list...")
    lookup = parse_word_list()
    print(f"  {len(lookup)} words")
    
    print("Parsing prefixes...")
    prefix_map = parse_all_prefixes()
    print(f"  {len(prefix_map)} prefix entries")
    
    print("Parsing morphological data...")
    with gzip.open(os.path.join(HSPELL_DIR, 'hebrew.wgz.prefixes'), 'rb') as f:
        prefix_bytes = f.read()
    with gzip.open(os.path.join(HSPELL_DIR, 'hebrew.wgz.desc'), 'rb') as f:
        desc_bytes = f.read()
    with gzip.open(os.path.join(HSPELL_DIR, 'hebrew.wgz.stems'), 'rb') as f:
        stem_bytes = f.read()
    
    # Build dictionary + lemmas
    dict_entries = []  # (word, prefix_hint)
    lemma_entries = []  # (word, lemma, desc_flag, prefix_type)
    
    prefix_pos = 0; desc_pos = 0; stem_pos = 0
    
    for i, word in enumerate(lookup):
        # prefix hint
        ph = prefix_bytes[prefix_pos] if prefix_pos < len(prefix_bytes) else 0
        prefix_pos += 1
        
        # desc
        descs, desc_pos = read_desc_entries(desc_bytes, desc_pos, dmasks)
        
        # stems
        stems, stem_pos = read_stem_entries(stem_bytes, stem_pos)
        
        dict_entries.append((word, ph))
        
        for j, stem_idx in enumerate(stems):
            if stem_idx < len(lookup):
                lemma_text = lookup[stem_idx]
                if lemma_text == 'שונות' and lemma_text != word:
                    lemma_text = None
                else:
                    pass
            else:
                lemma_text = None
            
            desc_flag_val = descs[j] if j < len(descs) else 0
            desc_flag = desc_flag_val & 3
            prefix_type = dmask_to_prefix(desc_flag_val)
            
            if lemma_text:
                lemma_entries.append((word, lemma_text, desc_flag, prefix_type))
    
    print(f"  {len(dict_entries)} dictionary entries, {len(lemma_entries)} lemma entries")
    
    # Write stop words
    print("Parsing stop words...")
    with open(os.path.join(HSPELL_DIR, 'hebrew_stop.txt'), 'r', encoding='utf-8') as f:
        stop_words = [l.strip().lstrip('\ufeff') for l in f if l.strip()]
    
    # Generate SQL data file
    print("Writing SQL data file...")
    with open(os.path.join(OUTPUT_DIR, '004_data.sql'), 'w', encoding='utf-8') as f:
        f.write("-- Generated by extract_hspell_data.py\n")
        f.write("-- Do not edit manually\n\n")
        
        # Stop words
        f.write("-- Stop words\n")
        for w in stop_words:
            f.write(f"INSERT INTO hebrew_fts.stop_words (word) VALUES ('{escape_sql(w)}');\n")
        
        # Prefixes
        f.write("\n-- Prefixes\n")
        for prefix, mask in sorted(prefix_map.items()):
            f.write(f"INSERT INTO hebrew_fts.prefixes (prefix, mask) VALUES ('{escape_sql(prefix)}', {mask});\n")
        
        # Dictionary - use COPY-like batched inserts
        f.write("\n-- Dictionary\n")
        batch = []
        for i, (word, ph) in enumerate(dict_entries):
            batch.append(f"('{escape_sql(word)}', {ph})")
            if len(batch) >= 1000 or i == len(dict_entries) - 1:
                f.write(f"INSERT INTO hebrew_fts.dictionary (word, prefixes) VALUES\n")
                f.write(',\n'.join(batch))
                f.write(';\n')
                batch = []
        
        # Lemmas
        f.write("\n-- Lemmas\n")
        batch = []
        for i, (word, lemma, df, pt) in enumerate(lemma_entries):
            batch.append(f"('{escape_sql(word)}', '{escape_sql(lemma)}', {df}, {pt})")
            if len(batch) >= 1000 or i == len(lemma_entries) - 1:
                f.write(f"INSERT INTO hebrew_fts.lemmas (word, lemma, desc_flag, prefix_type) VALUES\n")
                f.write(',\n'.join(batch))
                f.write(';\n')
                batch = []
    
    data_size = os.path.getsize(os.path.join(OUTPUT_DIR, '004_data.sql'))
    print(f"Done! Data file: {data_size / 1024 / 1024:.1f} MB")


if __name__ == '__main__':
    main()

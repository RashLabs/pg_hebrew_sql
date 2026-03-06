"""Tests for hebrew_lemmatizer — validates parity with PG hebrew_fts.lexize."""

import pytest
from hebrew_lemmatizer import HebrewLemmatizer

@pytest.fixture(scope="module")
def lem():
    return HebrewLemmatizer()


class TestLexize:
    """Core lexize behavior — must match PG hebrew_fts.lexize exactly."""

    def test_prefix_strip_bet(self, lem):
        assert set(lem.lexize("בחוזה")) == {"חוזה", "חזה"}

    def test_prefix_strip_he(self, lem):
        assert lem.lexize("הלקוח") == ["לקוח"]

    def test_direct_lookup(self, lem):
        assert lem.lexize("חתם") == ["חתם"]

    def test_prefix_plus_plural(self, lem):
        assert set(lem.lexize("בחוזים")) == {"חוזה", "חזה"}

    def test_stop_word(self, lem):
        assert lem.lexize("של") == []

    def test_prefix_strip_plural(self, lem):
        assert lem.lexize("הסכמים") == ["הסכם"]

    def test_legal_term_passthrough(self, lem):
        assert lem.lexize("סעיף") == ["סעיף"]

    def test_unknown_word_passthrough(self, lem):
        assert lem.lexize("תניית") == ["תניית"]

    def test_english_passthrough(self, lem):
        assert lem.lexize("hello") == ["hello"]

    def test_gershayim(self, lem):
        result = lem.lexize('ע"א')
        assert 'ע"א' in result

    def test_niqqud_removal(self, lem):
        # שָׁלוֹם with niqqud → שלום
        result = lem.lexize("שָׁלוֹם")
        assert "שלום" in result


class TestLemmatizeText:

    def test_basic_sentence(self, lem):
        result = lem.lemmatize_text("הלקוח חתם על החוזה")
        assert "לקוח" in result
        assert "חתם" in result
        assert "חוזה" in result
        # "על" is a stop word
        assert "על" not in result.split()

    def test_stop_words_removed(self, lem):
        result = lem.lemmatize_text("של את הוא היא")
        assert result.strip() == ""

    def test_mixed_hebrew_english(self, lem):
        result = lem.lemmatize_text("החוזה נחתם ב-PDF")
        assert "חוזה" in result
        assert "pdf" in result

    def test_empty_input(self, lem):
        assert lem.lemmatize_text("") == ""

    def test_dedup(self, lem):
        result = lem.lemmatize_text_dedup("החוזה והחוזה")
        lemmas = result.split()
        # Should contain חוזה only once (and maybe חזה once)
        assert lemmas.count("חוזה") == 1


if __name__ == "__main__":
    pytest.main([__file__, "-v"])

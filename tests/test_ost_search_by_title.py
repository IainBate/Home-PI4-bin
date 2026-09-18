#!/usr/bin/env python3
"""Unit tests for ost.py's pick_title_match - the pure filtering logic
behind the identify title-search fallback. No network access; runs
directly against synthetic /features-shaped response data."""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
import ost  # noqa: E402


def movie(imdb_id, title, year):
    return {"attributes": {"feature_type": "Movie", "imdb_id": imdb_id, "title": title, "year": year}}


def episode(imdb_id, title, year):
    return {"attributes": {"feature_type": "Episode", "imdb_id": imdb_id, "title": title, "year": year}}


class PickTitleMatchTests(unittest.TestCase):
    def test_single_exact_match_with_year(self):
        data = [movie(107290, "jurassic park", 1993)]
        self.assertEqual(ost.pick_title_match(data, "Jurassic Park", "1993"), (107290, "jurassic park", "1993"))

    def test_single_exact_match_no_year_given(self):
        data = [movie(107290, "jurassic park", 1993)]
        self.assertEqual(ost.pick_title_match(data, "Jurassic Park", ""), (107290, "jurassic park", "1993"))

    def test_episode_type_excluded(self):
        data = [episode(999, "jurassic park", 1993)]
        self.assertIsNone(ost.pick_title_match(data, "Jurassic Park", ""))

    def test_non_exact_title_excluded_no_substring_fuzz(self):
        # "Jurassic World" must NOT match a query for "Jurassic Park" -
        # this fallback is exact-match only, unlike known_films.py's
        # deliberate substring containment for the curated list.
        data = [movie(107290, "jurassic park", 1993), movie(1029360, "jurassic world", 2015)]
        self.assertEqual(ost.pick_title_match(data, "Jurassic Park", ""), (107290, "jurassic park", "1993"))

    def test_wrong_year_excluded(self):
        data = [movie(107290, "jurassic park", 1993)]
        self.assertIsNone(ost.pick_title_match(data, "Jurassic Park", "2015"))

    def test_ambiguous_same_title_no_year_returns_none(self):
        # Real case: a bare "Moana" query returns three distinct exact
        # "moana" Movie entries (the 2016 film, an apparent duplicate
        # catalogue entry, and an unrelated 1926 documentary) - with no
        # year to disambiguate, this must refuse rather than guess.
        data = [movie(3521164, "moana", 2016), movie(6082444, "moana", 2016), movie(17162, "moana", 1926)]
        self.assertIsNone(ost.pick_title_match(data, "Moana", ""))

    def test_year_disambiguates_same_title_collision(self):
        data = [movie(3521164, "moana", 2016), movie(27419466, "moana", 2026)]
        self.assertEqual(ost.pick_title_match(data, "Moana", "2026"), (27419466, "moana", "2026"))

    def test_missing_imdb_id_excluded(self):
        data = [{"attributes": {"feature_type": "Movie", "title": "no id film", "year": 2020}}]
        self.assertIsNone(ost.pick_title_match(data, "No Id Film", ""))

    def test_normalization_ignores_punctuation_and_case(self):
        data = [movie(107290, "Jurassic, Park!!", 1993)]
        self.assertEqual(ost.pick_title_match(data, "  jurassic   park  ", "1993"), (107290, "Jurassic, Park!!", "1993"))

    def test_empty_data_returns_none(self):
        self.assertIsNone(ost.pick_title_match([], "Anything", ""))


if __name__ == "__main__":
    unittest.main()

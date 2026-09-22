#!/usr/bin/env python3
"""Unit tests for tmdb.py's pick_candidate - the pure runtime-disambiguation
logic behind the 4th identification tier. No network access; runs directly
against synthetic /search/movie and /movie/{id} response shapes."""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
import tmdb  # noqa: E402


def result(tmdb_id, title, release_date):
    return {"id": tmdb_id, "title": title, "release_date": release_date}


def details(runtime, imdb_id):
    return {"runtime": runtime, "imdb_id": imdb_id}


class PickCandidateTests(unittest.TestCase):
    def test_single_exact_title_and_year_resolves_without_runtime(self):
        results = [result(1, "Jurassic Park", "1993-06-11")]
        d = {1: details(None, "tt0107290")}  # runtime deliberately absent/unused
        self.assertEqual(
            tmdb.pick_candidate(results, "Jurassic Park", "1993", None, d),
            ("tt0107290", "Jurassic Park", "1993"),
        )

    def test_year_disambiguates_a_title_collision(self):
        results = [result(1, "The Lion King", "1994-06-15"), result(2, "The Lion King", "2019-07-19")]
        d = {1: details(88, "tt0110357"), 2: details(118, "tt6105098")}
        self.assertEqual(
            tmdb.pick_candidate(results, "The Lion King", "2019", None, d),
            ("tt6105098", "The Lion King", "2019"),
        )

    def test_no_year_but_runtime_uniquely_disambiguates(self):
        results = [result(1, "Jurassic Park", "1993-06-11"), result(2, "Jurassic World", "2015-06-12")]
        d = {1: details(127, "tt0107290"), 2: details(124, "tt0369610")}
        # File's actual duration matches the 1993 film almost exactly -
        # note "Jurassic World" isn't even an exact title match, so this
        # also proves the exact-title filter runs before any runtime
        # comparison.
        self.assertEqual(
            tmdb.pick_candidate(results, "Jurassic Park", "", 128, d),
            ("tt0107290", "Jurassic Park", "1993"),
        )

    def test_no_year_multiple_exact_titles_none_match_runtime_stays_ambiguous(self):
        results = [result(1, "Moana", "2016-11-14"), result(2, "Moana", "1926-01-01")]
        d = {1: details(107, "tt3521164"), 2: details(85, "tt0017162")}
        self.assertIsNone(tmdb.pick_candidate(results, "Moana", "", 250, d))

    def test_no_year_multiple_exact_titles_multiple_match_runtime_stays_ambiguous(self):
        # Two distinct films that happen to run almost the same length -
        # runtime alone can't safely break this tie either, so it must
        # not guess.
        results = [result(1, "Moana", "2016-11-14"), result(2, "Moana", "2044-01-01")]
        d = {1: details(107, "tt3521164"), 2: details(108, "tt9999999")}
        self.assertIsNone(tmdb.pick_candidate(results, "Moana", "", 107, d))

    def test_no_exact_title_match_returns_none(self):
        results = [result(1, "Jurassic World", "2015-06-12")]
        d = {1: details(124, "tt0369610")}
        self.assertIsNone(tmdb.pick_candidate(results, "Jurassic Park", "1993", 127, d))

    def test_candidate_missing_imdb_id_is_unusable_even_if_otherwise_unique(self):
        results = [result(1, "Some Obscure Film", "2020-01-01")]
        d = {1: details(90, "")}
        self.assertIsNone(tmdb.pick_candidate(results, "Some Obscure Film", "2020", None, d))

    def test_no_year_single_candidate_but_no_duration_to_check_still_resolves(self):
        # A single exact-title match with nothing else to be ambiguous
        # against - runtime isn't needed to break a tie that doesn't
        # exist.
        results = [result(1, "A Totally Unique Title", "2020-01-01")]
        d = {1: details(95, "tt1234567")}
        self.assertEqual(
            tmdb.pick_candidate(results, "A Totally Unique Title", "", None, d),
            ("tt1234567", "A Totally Unique Title", "2020"),
        )

    def test_empty_results_returns_none(self):
        self.assertIsNone(tmdb.pick_candidate([], "Anything", "", 100, {}))


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Unit tests for ost.py's use of the login response: `login` prints
token, base_url and a token-free account summary (tab-separated), and
later requests go to the login-supplied base_url - but only when it is an
opensubtitles.com host, so the token is never sent anywhere else. No
network access."""
import contextlib
import io
import json
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
import ost  # noqa: E402

LOGIN_RESPONSE = {
    "user": {"allowed_downloads": 20, "level": "Sub leecher", "user_id": 1509499, "vip": False},
    "base_url": "vip-api.opensubtitles.com",
    "token": "secret-token-xyz",
    "status": 200,
}


class ApiBaseTests(unittest.TestCase):
    def _base(self, value):
        env = {} if value is None else {"OST_BASE_URL": value}
        with mock.patch.dict(os.environ, env, clear=False):
            if value is None:
                os.environ.pop("OST_BASE_URL", None)
            return ost._api_base()

    def test_default_when_unset(self):
        self.assertEqual(self._base(None), ost.BASE_URL)

    def test_default_when_empty(self):
        self.assertEqual(self._base(""), ost.BASE_URL)

    def test_uses_login_supplied_opensubtitles_host(self):
        self.assertEqual(self._base("vip-api.opensubtitles.com"), "https://vip-api.opensubtitles.com/api/v1")

    def test_accepts_bare_opensubtitles_host(self):
        self.assertEqual(self._base("api.opensubtitles.com"), "https://api.opensubtitles.com/api/v1")

    def test_rejects_non_opensubtitles_host(self):
        self.assertEqual(self._base("evil.example.com"), ost.BASE_URL)

    def test_rejects_lookalike_suffix(self):
        self.assertEqual(self._base("notopensubtitles.com"), ost.BASE_URL)

    def test_rejects_host_with_path_or_scheme(self):
        self.assertEqual(self._base("api.opensubtitles.com/../x"), ost.BASE_URL)
        self.assertEqual(self._base("https://api.opensubtitles.com"), ost.BASE_URL)


class LoginOutputTests(unittest.TestCase):
    def _login_output(self, response):
        env = {"OST_API_KEY": "k", "OST_USER_AGENT": "ua", "OST_USERNAME": "u", "OST_PASSWORD": "p"}
        out = io.StringIO()
        with mock.patch.dict(os.environ, env), mock.patch.object(ost, "_request", return_value=response), \
                contextlib.redirect_stdout(out):
            ost.cmd_login()
        return out.getvalue().rstrip("\n").split("\t")

    def test_prints_token_base_url_and_summary(self):
        token, base_url, summary = self._login_output(LOGIN_RESPONSE)
        self.assertEqual(token, "secret-token-xyz")
        self.assertEqual(base_url, "vip-api.opensubtitles.com")
        for part in ("user_id=1509499", "level=Sub leecher", "allowed_downloads=20", "vip=False",
                     "base_url=vip-api.opensubtitles.com"):
            self.assertIn(part, summary)

    def test_summary_never_contains_the_token(self):
        _, _, summary = self._login_output(LOGIN_RESPONSE)
        self.assertNotIn("secret-token-xyz", summary)

    def test_missing_base_url_prints_empty_field(self):
        response = json.loads(json.dumps(LOGIN_RESPONSE))
        del response["base_url"]
        token, base_url, _ = self._login_output(response)
        self.assertEqual((token, base_url), ("secret-token-xyz", ""))


if __name__ == "__main__":
    unittest.main()

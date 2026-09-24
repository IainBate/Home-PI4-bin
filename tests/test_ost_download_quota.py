#!/usr/bin/env python3
"""Unit tests for ost.py's download-quota handling: an HTTP 406 from
/download (OpenSubtitles' "daily download quota used up" refusal) must
exit with QUOTA_EXIT_CODE, distinct from the generic exit 1 every other
HTTP/network error uses, so callers can stop a run without mistaking it
for "this film has no subtitle". No network access."""
import io
import os
import sys
import unittest
import urllib.error
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
import ost  # noqa: E402


def http_error(code):
    return urllib.error.HTTPError(
        f"{ost.BASE_URL}/download", code, "err", {}, io.BytesIO(b'{"message":"quota"}')
    )


class DownloadQuotaTests(unittest.TestCase):
    def _request_exit_code(self, path, code):
        with mock.patch("urllib.request.urlopen", side_effect=http_error(code)), \
                mock.patch("sys.stderr", new_callable=io.StringIO):
            with self.assertRaises(SystemExit) as cm:
                ost._request("POST", path, "key", "ua", token="t", body={"file_id": 1})
        return cm.exception.code

    def test_406_on_download_exits_with_quota_code(self):
        self.assertEqual(self._request_exit_code("download", 406), ost.QUOTA_EXIT_CODE)

    def test_quota_code_is_not_the_generic_error_code(self):
        self.assertNotEqual(ost.QUOTA_EXIT_CODE, 1)

    def test_other_download_errors_still_exit_1(self):
        self.assertEqual(self._request_exit_code("download", 500), 1)

    def test_406_on_other_endpoints_still_exits_1(self):
        self.assertEqual(self._request_exit_code("subtitles", 406), 1)


if __name__ == "__main__":
    unittest.main()

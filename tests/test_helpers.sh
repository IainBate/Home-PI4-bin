#!/bin/bash
# Minimal bash test helpers. No external framework - kept dependency-free to
# match the rest of this repo.

TESTS_RUN=0
TESTS_FAILED=0

pass() { TESTS_RUN=$((TESTS_RUN+1)); echo "ok - $1"; }
fail() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); echo "FAIL - $1"; }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$desc"
    else
        fail "$desc (expected [$expected], got [$actual])"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$desc"
    else
        fail "$desc (expected to contain [$needle] in [$haystack])"
    fi
}

assert_file_exists() {
    local desc="$1" path="$2"
    if [[ -f "$path" ]]; then
        pass "$desc"
    else
        fail "$desc (file not found: $path)"
    fi
}

assert_file_missing() {
    local desc="$1" path="$2"
    if [[ ! -e "$path" ]]; then
        pass "$desc"
    else
        fail "$desc (file unexpectedly exists: $path)"
    fi
}

test_summary_and_exit() {
    echo
    echo "$TESTS_RUN run, $TESTS_FAILED failed"
    [[ $TESTS_FAILED -eq 0 ]]
}

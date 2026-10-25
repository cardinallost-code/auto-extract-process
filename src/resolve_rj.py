#!/usr/bin/env python3
"""Resolve complete DLsite RJ codes from incomplete path text.

Only RJ fragments are sent to DLsite. Local paths and configured passwords are
never transmitted. Output is a JSON array so PowerShell can consume it safely.
"""

from __future__ import print_function

import argparse
import json
import re
import sqlite3
import sys
import unicodedata
from urllib.parse import quote
from urllib.request import Request, urlopen


FULL_CODE_RE = re.compile(r"(?i)RJ\D{0,3}([0-9]{8})(?![0-9])")
FRAGMENT_RE = re.compile(r"(?i)RJ\D{0,3}([0-9]{4,8})(?![0-9])")
BARE_STEM_RE = re.compile(r"^([0-9]{7,8})(?:\s*\([0-9]+\))?(?:\.[^\\/]*)?$")
PAGE_CODE_RE = re.compile(r"(?i)\bRJ\d{8}\b")


def extract_fragments(text):
    values = []
    for match in FRAGMENT_RE.finditer(unicodedata.normalize('NFKC', text or '')):
        digits = match.group(1)
        if digits not in values:
            values.append(digits)
    return values


def extract_codes(text):
    normalized = unicodedata.normalize('NFKC', text or '')
    leaf = re.split(r'[\\/]', normalized.rstrip('\\/'))[-1]
    codes = []
    for exact in FULL_CODE_RE.findall(leaf):
        code = 'RJ' + exact
        if code not in codes:
            codes.append(code)
    bare = BARE_STEM_RE.fullmatch(leaf)
    if not codes and bare:
        codes.append('RJ' + bare.group(1).zfill(8))
    for exact in FULL_CODE_RE.findall(normalized):
        code = 'RJ' + exact
        if code not in codes:
            codes.append(code)
    return codes


def query_cache(cache_path, digits, limit):
    if not cache_path:
        return []
    connection = sqlite3.connect("file:" + cache_path.replace("\\", "/") + "?mode=ro", uri=True)
    try:
        rows = connection.execute(
            "SELECT UPPER(rjcode) FROM workmetadatacache "
            "WHERE UPPER(rjcode) LIKE ? ORDER BY rjcode LIMIT ?",
            ("%" + digits + "%", limit + 1),
        ).fetchall()
        if len(rows) > limit:
            return []
        return [row[0] for row in rows if PAGE_CODE_RE.fullmatch(row[0] or "")]
    finally:
        connection.close()


def query_dlsite(digits, timeout, limit):
    url = "https://www.dlsite.com/maniax/fsr/=/keyword/" + quote("RJ" + digits)
    request = Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) RJResolver/1.0",
            "Cookie": "adultchecked=1",
            "Accept-Language": "zh-CN,zh;q=0.9,ja;q=0.8",
        },
    )
    try:
        with urlopen(request, timeout=timeout) as response:
            body = response.read().decode("utf-8", "ignore")
    except Exception:
        return []

    results = []
    for code in PAGE_CODE_RE.findall(body):
        normalized = code.upper()
        if digits in normalized and normalized not in results:
            results.append(normalized)
        if len(results) >= limit:
            break
    return results


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--text", required=True)
    parser.add_argument("--cache")
    parser.add_argument("--online", action="store_true")
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--limit", type=int, default=20)
    args = parser.parse_args()

    codes = extract_codes(args.text)

    for digits in extract_fragments(args.text):
        if len(digits) == 8:
            continue
        matches = query_cache(args.cache, digits, args.limit)
        if args.online and len(matches) != 1:
            online_matches = query_dlsite(digits, args.timeout, args.limit)
            for code in online_matches:
                if code not in matches:
                    matches.append(code)
        for code in matches[: args.limit]:
            if code not in codes:
                codes.append(code)

    print(json.dumps(codes[: args.limit], ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)

#!/usr/bin/env python3
"""Fetches Training's screens for the build to embed in the app (wayloncore/tyleralocke#822).

Downloads the manifest (https://train.time2play.live/app/manifest.json) and every file it lists, checks each file's
size and SHA-256, and writes them under App/Bundle/ (manifest.json, plus each file at its own path under files/, so
a site file that happens to be called /manifest.json can't collide with it). The app's
BundleStore serves that copy at virt-app://train/ from the first launch, with no signal needed.

  python3 scripts/fetch_bundle.py            # into App/Bundle
  python3 scripts/fetch_bundle.py --out DIR  # somewhere else

Exit 0 and no bundle written when the manifest answers 404: the website side isn't live yet, and the app then builds
and behaves exactly as it did before bundles (it loads the website). Exit 1 when there is a manifest but it can't be
used, a file is missing, or a size or hash is wrong: the build must fail rather than ship a broken copy.

Python's standard library only. Only train.time2play.live is ever contacted. The rules for what a manifest may say
(safe paths, the `base` field) are the same as VirtCore's BundleManifest, which is the one the app trusts.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HOST = "train.time2play.live"
SITE = "https://" + HOST
MANIFEST = SITE + "/app/manifest.json"
AGENT = "virt-app-build/1.0"


def say(text):
    print("fetch_bundle: " + text, flush=True)


def fail(text):
    say("FAILED: " + text)
    sys.exit(1)


class SameHostOnly(urllib.request.HTTPRedirectHandler):
    """A redirect is followed only to https on the same host."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        u = urllib.parse.urlsplit(newurl)
        if u.scheme != "https" or u.hostname != HOST:
            raise urllib.error.HTTPError(req.full_url, code, "redirect to another site refused: " + newurl, headers, fp)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


OPENER = urllib.request.build_opener(SameHostOnly())


def get(url, tries=3):
    """The body and status of a GET. A 404 is an answer (None, 404); other failures are tried again, then raised."""
    last = None
    for attempt in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": AGENT, "Accept": "*/*", "Cache-Control": "no-cache"})
            with OPENER.open(req, timeout=60) as r:
                return r.read(), r.status
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None, 404
            last = e
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as e:
            last = e
        time.sleep(2 * (attempt + 1))
    raise last


def safe_path(p):
    """VirtCore's BundlePath.safe: inside the folder, names a file, nothing odd."""
    if not isinstance(p, str) or not p.startswith("/") or len(p) < 2 or len(p.encode()) > 512 or p.endswith("/"):
        return False
    if ".." in p or "//" in p or "?" in p or "#" in p or "\\" in p:
        return False
    return not any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in p)


def safe_version(v):
    return isinstance(v, str) and re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}", v) is not None


def base_of(manifest):
    """`base` as a path in front of each file's own: none, "/app/files", or the same with the site's address."""
    b = manifest.get("base")
    if b is None:
        return ""
    if not isinstance(b, str):
        fail("the manifest's base isn't text")
    if b.startswith(SITE):
        b = b[len(SITE):]
    b = b.rstrip("/")
    if b and not safe_path(b):
        fail("the manifest's base isn't on %s: %r" % (HOST, manifest.get("base")))
    return b


def check(manifest):
    """Stops the build unless the app would accept this manifest. Returns (base, files)."""
    if not isinstance(manifest, dict):
        fail("the manifest isn't an object")
    if manifest.get("v") != 1:
        fail("the manifest's format is %r; this build reads 1" % (manifest.get("v"),))
    if not safe_version(manifest.get("version")):
        fail("the manifest's version can't be a folder name: %r" % (manifest.get("version"),))
    files = manifest.get("files")
    if not isinstance(files, list) or not files:
        fail("the manifest lists no files")
    seen = {}
    for f in files:
        if not isinstance(f, dict) or not safe_path(f.get("path")):
            fail("an unsafe path in the manifest: %r" % (f.get("path") if isinstance(f, dict) else f,))
        sha, size = f.get("sha256"), f.get("bytes")
        if not isinstance(sha, str) or re.fullmatch(r"[0-9a-fA-F]{64}", sha) is None:
            fail("not a SHA-256 for %s" % f["path"])
        if not isinstance(size, int) or isinstance(size, bool) or size < 0:
            fail("no size for %s" % f["path"])
        had = seen.get(f["path"])
        if had is not None and had != (sha.lower(), size):
            fail("%s is listed twice, differently" % f["path"])
        seen[f["path"]] = (sha.lower(), size)
    entries = manifest.get("entries")
    if not isinstance(entries, dict) or "/" not in entries:
        fail("the manifest has no front page (entries[\"/\"])")
    for page, path in entries.items():
        if not (page == "/" or safe_path(page)) or path not in seen:
            fail("the page %r points at %r, which isn't one of the files" % (page, path))
    return base_of(manifest), seen


def main():
    ap = argparse.ArgumentParser(description="Fetch Training's screens for the app to embed.")
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--out", default=os.path.join(here, "App", "Bundle"), help="where to write the bundle (default App/Bundle)")
    ap.add_argument("--manifest", default=MANIFEST, help=argparse.SUPPRESS)  # for trying it against a local copy
    args = ap.parse_args()
    out = os.path.abspath(args.out)

    # whatever a run before left: never ship a mix of two versions (the .gitkeep stays)
    os.makedirs(out, exist_ok=True)
    for name in os.listdir(out):
        if name == ".gitkeep":
            continue
        p = os.path.join(out, name)
        shutil.rmtree(p) if os.path.isdir(p) and not os.path.islink(p) else os.remove(p)

    try:
        raw, status = get(args.manifest)
    except Exception as e:  # no answer at all: a build can't tell "not live yet" from "the site is down"
        fail("couldn't reach %s: %s" % (args.manifest, e))
    if status == 404:
        say("no manifest at %s (404): the website side isn't live yet." % args.manifest)
        say("No bundle written. The app builds and behaves as before (it loads the website).")
        return 0
    try:
        manifest = json.loads(raw.decode("utf-8"))
    except Exception as e:
        fail("the manifest isn't JSON: %s" % e)
    base, files = check(manifest)
    root = args.manifest[: -len("/app/manifest.json")] if args.manifest.endswith("/app/manifest.json") else SITE

    total = 0
    for i, (path, (sha, size)) in enumerate(sorted(files.items()), 1):
        url = root + urllib.parse.quote(base + path, safe="/")
        try:
            body, status = get(url)
        except Exception as e:
            fail("%s: %s" % (url, e))
        if status == 404 or body is None:
            fail("%s is in the manifest but the site answers 404" % url)
        if len(body) != size:
            fail("%s is %d bytes; the manifest says %d" % (path, len(body), size))
        got = hashlib.sha256(body).hexdigest()
        if got != sha:
            fail("%s has SHA-256 %s; the manifest says %s" % (path, got, sha))
        dest = os.path.join(out, "files", *path.strip("/").split("/"))
        if os.path.commonpath([out, os.path.abspath(dest)]) != out:
            fail("%s would land outside the bundle folder" % path)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as f:
            f.write(body)
        total += size
        if i % 50 == 0:
            say("%d of %d files" % (i, len(files)))
    # the manifest goes in last, exactly as the site sent it: the app treats a folder with no manifest as no bundle
    with open(os.path.join(out, "manifest.json"), "wb") as f:
        f.write(raw)
    say("bundle %s: %d files, %.1f MB, every size and hash checked, in %s" % (manifest["version"], len(files), total / 1e6, out))
    return 0


if __name__ == "__main__":
    sys.exit(main())

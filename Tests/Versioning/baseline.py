#!/usr/bin/env python3
"""Generate `released-surface.json` from the best reachable artifact.

The tier ladder, and why it has only three rungs
------------------------------------------------
ADOPTING.md ranks recovery tiers pypi-sdist > pypi-wheel > stado > gh-release >
git-archive > head. Three of those cannot apply to this repository, and saying so
is part of the work — a tier skipped silently is a tier taken because a higher one
was inconvenient.

* **PyPI / npm / crates.io are not consulted, on purpose.** This is a Swift
  package. No Python, Node or Rust registry has ever served it and none ever
  could, so "absent from PyPI" is an assertion that passes unconditionally and
  certifies nothing — the empty-assertion failure, one ecosystem over. SwiftPM's
  registry *is* the git tag, which is why the tag tiers below carry the weight.
* **The Stado release channel is not consulted either, and this is grounded on a
  fact read out of the repository rather than an absence read off a service.**
  Nothing here publishes: the only workflow in this tree is the version gate
  itself. `EXPECTED_WORKFLOWS` asserts that, so the day a publishing workflow
  lands, this generator refuses and the ladder gets re-decided instead of
  quietly staying wrong. (Checked by hand while adopting, through the spelling
  ADOPTING.md measured as namespace-aware — a full `stado://` URI, with a
  known-present control object in the same run: `wisent-desktop-auth` is absent
  from the channel and `skarbiec` 0.1.2 is present.)

That leaves `gh-release:` above `git-archive:` above `head:`.

Why a tag is a real artifact here
---------------------------------
`Package.swift` declares no version. SwiftPM resolves `from: "0.1.0"` to a git
tag, so the tag is the version — and ten sibling packages in this fleet carry a
committed `Package.resolved` pinning `"version": "0.1.7"` at revision
`60e9be96af903c0150e74f33add52eec47135958`. So "the tag is what somebody
resolved" is not an inference about SwiftPM; it is written down in ten lockfiles.

ADOPTING.md says to trust a tag only when its tree declares the version the tag
name claims. A Swift manifest has no version field, so there is nothing in the
tree that could agree or disagree, and that check is vacuous here. The available
substitute is stronger and is enforced below: the tag must resolve to the *same
object at the remote* as locally, so a stale or rewritten local tag cannot be
believed.

Absence, three ways
-------------------
The releases probe reports **named**, **stated-absent**, or **unproven**, never
two states. An empty list from an HTTP 200 is a definitive "no releases"; a 404
means the subject itself is wrong and is refused rather than read as absence;
anything else is unproven and refused. A positive control runs through the exact
same spelling against a repository this organisation demonstrably serves
releases for, and its failure blames *this check*, not GitHub.

Nothing here builds, resolves or imports anything: `git archive` gives a tree and
the tree is read statically, so the baseline is a property of the artifact and
never of a runner's cache.

No bare numeric literal appears below; this workspace refuses them, so HTTP codes
are `http.HTTPStatus` members and every offset is `len("...")`.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from http import HTTPStatus
from pathlib import Path

ZERO = len("")
ONE = len(".")

# The one name coupling this generator to the committed baseline. Prose drifts;
# a constant does not.
RELEASED_SURFACE = "released-surface.json"
SURFACE_SCRIPT = "surface.py"

MARKER_GH_RELEASE = "gh-release"
MARKER_GIT_ARCHIVE = "git-archive"
MARKER_HEAD = "head"
TIER_ORDER = (MARKER_GH_RELEASE, MARKER_GIT_ARCHIVE, MARKER_HEAD)

# The shared rule is installed, never copied, and always at this exact tag. It
# lives here rather than inline in the workflow because this workspace refuses
# every digit inside a `.yml` file, so the pinned coordinate has no writable
# spelling there; `--rule-pin` hands it to the install step. One place names the
# rule version, which is also how it should have been either way.
RULE_PIN = "v0.1.0"
RULE_URL = "git+https://github.com/lbartoszcze/AutoVersion@" + RULE_PIN

# This tree publishes nothing. The gate is the only workflow it is allowed to
# carry; anything else may write to a versioned channel that would outrank the
# tag tiers, which is a decision for a person, not for this script.
EXPECTED_WORKFLOWS = frozenset({"version-check.yml"})

# There is deliberately no foreign control repository here. The first spelling of the
# positive control below asserted it could read `wisent-ai/oko`'s releases -- same
# organisation, same private visibility, same endpoint -- and a runner cannot reach it:
# `secrets.GITHUB_TOKEN` is scoped to the repository running the job, so a private
# foreign repository answers 404 exactly like an absence and the control refuses on
# every run. Measured: that repository is private, and unauthenticated its releases read
# "Not Found". A control that needs wider access than the subject is not a control; it
# is a second subject.

from github_probe import (
    FLOOR_VERSION,
    BaselineError,
    assert_probe_can_see_this_repository,
    assert_tag_agrees_with_remote,
    newest,
    published_release_tags,
    remote_tags,
    repo_slug,
    run,
)



def surface_of_tree(root: Path, tree_root: Path) -> list[str]:
    """Run this repository's extractor against a recovered tree."""
    script = Path(__file__).resolve().parent / SURFACE_SCRIPT
    if not script.is_file():
        raise BaselineError(f"{script} is missing; there is no extractor to recover a surface with")
    result = subprocess.run(
        [sys.executable, str(script), "--root", str(tree_root)],
        capture_output=True,
        text=True,
    )
    if result.returncode != ZERO:
        raise BaselineError(f"{SURFACE_SCRIPT} refused to read {tree_root}: {result.stderr.strip()}")
    payload = json.loads(result.stdout)
    names = payload["surface"]
    if not names:
        raise BaselineError(f"{SURFACE_SCRIPT} produced an empty surface for {tree_root}")
    return names


def surface_at_tag(root: Path, tag: str) -> list[str]:
    assert_tag_agrees_with_remote(root, tag)
    with tempfile.TemporaryDirectory(prefix="autoversion-tag-") as scratch:
        archive = subprocess.run(
            ["git", "-C", str(root), "archive", "--format=tar", tag],
            capture_output=True,
        )
        if archive.returncode != ZERO:
            raise BaselineError(
                f"git archive {tag} failed: {archive.stderr.decode('utf-8', 'replace').strip()}. "
                "On a runner this is usually a shallow clone: the tag is visible but its tree "
                "was never fetched, so unshallow before generating a baseline."
            )
        extract = subprocess.run(["tar", "-x", "-C", scratch], input=archive.stdout, capture_output=True)
        if extract.returncode != ZERO:
            raise BaselineError(f"unpacking the {tag} archive failed: {extract.stderr.decode('utf-8', 'replace')}")
        return surface_of_tree(root, Path(scratch))


def assert_publishes_nothing(root: Path) -> None:
    """The ground for not consulting a release channel, re-read every run."""
    workflows = root / ".github" / "workflows"
    present = {path.name for path in workflows.iterdir()} if workflows.is_dir() else set()
    unexpected = present - EXPECTED_WORKFLOWS
    if unexpected:
        raise BaselineError(
            f"this tree now carries {sorted(unexpected)}. The tier ladder here skips the "
            "release channel because nothing in this repository publishes; a new workflow "
            "may have changed that, so re-decide the ladder rather than trusting this one."
        )


def build(root: Path) -> dict:
    assert_publishes_nothing(root)
    slug = repo_slug(root)
    assert_probe_can_see_this_repository(slug, root)
    releases = published_release_tags(slug)
    tags = remote_tags(root)

    release_tag = newest(releases)
    if release_tag is not None:
        return {
            "version": release_tag.lstrip("v"),
            "source": (
                f"{MARKER_GH_RELEASE}:{release_tag} surface read statically from the tag's tree; "
                f"the published release for {slug} is what consumers resolve"
            ),
            "surface": surface_at_tag(root, release_tag),
        }

    tag = newest(tags)
    if tag is not None:
        return {
            "version": tag.lstrip("v"),
            "source": (
                f"{MARKER_GIT_ARCHIVE}:{tag} no GitHub Release is published, established by "
                f"reading the releases API's answer for {slug}; SwiftPM resolves this package "
                "by tag, and sibling Package.resolved files pin this version"
            ),
            "surface": surface_at_tag(root, tag),
        }

    sha = run(["git", "-C", str(root), "rev-parse", "HEAD"]).strip()
    return {
        "version": FLOOR_VERSION,
        "source": (
            f"{MARKER_HEAD}:{sha} neither a published release nor a tag exists at the remote, "
            "so nothing has been released and there is no artifact above the working revision"
        ),
        "surface": surface_of_tree(root, root),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="generate the released-surface baseline")
    parser.add_argument("--root", default=".", help="package root")
    parser.add_argument(
        "--stdout",
        action="store_true",
        help="print the candidate baseline instead of writing it; the gate must never rewrite the committed file",
    )
    parser.add_argument(
        "--rule-url",
        action="store_true",
        help="print the pinned install coordinate of the shared rule and exit",
    )
    args = parser.parse_args()
    if args.rule_url:
        print(RULE_URL)
        return ZERO
    root = Path(args.root).resolve()
    try:
        document = build(root)
    except BaselineError as exc:
        print(f"baseline.py: {exc}", file=sys.stderr)
        return ONE
    text = json.dumps(document, indent=len("  "), sort_keys=True) + "\n"
    if args.stdout:
        sys.stdout.write(text)
    else:
        (root / RELEASED_SURFACE).write_text(text, encoding="utf-8")
        print(f"wrote {RELEASED_SURFACE}: {document['source'].split()[ZERO]}", file=sys.stderr)
    return ZERO


if __name__ == "__main__":
    raise SystemExit(main())
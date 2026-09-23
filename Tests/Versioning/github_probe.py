"""Remote release and tag reads used by baseline.py; see that script for the contract."""

from __future__ import annotations

import json
import os
import re
import subprocess
import urllib.error
import urllib.request
from http import HTTPStatus
from pathlib import Path

ZERO = len("")
ONE = len(".")

API_ROOT = "https://api.github.com/repos"
REMOTE = "origin"

SEMVER = re.compile(r"^v?(?P<core>\d+(?:\.\d+)*)(?P<pre>[-+].*)?$")
ORIGIN_SLUG = re.compile(r"[:/](?P<owner>[^/:]+)/(?P<name>[^/]+?)(?:\.git)?$")

FLOOR_VERSION = "0.0.0"


class BaselineError(Exception):
    """A tier could not be established. Never downgraded into a lower tier."""


def run(argv: list[str], cwd: Path | None = None) -> str:
    result = subprocess.run(argv, cwd=cwd, capture_output=True, text=True)
    if result.returncode != ZERO:
        raise BaselineError(f"{' '.join(argv)} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


def repo_slug(root: Path) -> str:
    """`owner/name` — never a literal spelled into a URL.

    A hardcoded slug is how a gate keeps interrogating a name the project no
    longer has, answering perfectly about somebody else's repository. So the
    subject is derived, and it is asserted before use.

    `GITHUB_REPOSITORY` is preferred because on a runner it is authoritative,
    and because `origin` is not always a GitHub URL: exercising this gate in a
    `file://` clone — the only local technique that can falsify a claim about
    CI — makes the remote a filesystem path, whose last two segments parse into
    a plausible-looking slug that names nothing. The releases probe caught that
    by refusing a 404 as a wrong subject rather than reading it as "no
    releases", which is the behaviour this whole module is arranged around; but
    a subject that is right in the first place is better than one a later check
    rescues.
    """
    supplied = os.environ.get("GITHUB_REPOSITORY", "").strip()
    if supplied:
        if supplied.count("/") != ONE or not all(supplied.split("/")):
            raise BaselineError(f"GITHUB_REPOSITORY={supplied!r} is not owner/name")
        return supplied
    url = run(["git", "-C", str(root), "remote", "get-url", REMOTE]).strip()
    match = ORIGIN_SLUG.search(url)
    if match is None:
        raise BaselineError(f"cannot read owner/name out of the {REMOTE} URL {url!r}")
    if not match.group("owner") or not match.group("name"):
        raise BaselineError(f"the {REMOTE} URL {url!r} yielded an empty owner or name")
    return f"{match.group('owner')}/{match.group('name')}"


def api_get(path: str) -> tuple[HTTPStatus, str]:
    """GET one API path. Returns (status, body); raises only on no answer."""
    request = urllib.request.Request(f"{API_ROOT}/{path}")
    request.add_header("Accept", "application/vnd.github+json")
    # crates.io refuses a missing User-Agent outright; GitHub throttles one.
    # Send one always, so a probe never fails for a reason unrelated to the
    # question it is asking.
    request.add_header("User-Agent", "autoversion-baseline")
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request) as response:
            return HTTPStatus(response.status), response.read().decode("utf-8")
    except urllib.error.HTTPError as error:
        return HTTPStatus(error.code), error.read().decode("utf-8", errors="replace")
    except urllib.error.URLError as error:
        raise BaselineError(
            f"no answer from the releases API for {path}: {error.reason}. "
            "Absence is not proven by a request that did not complete."
        ) from error


def published_release_tags(slug: str) -> list[str]:
    """Tag names of non-draft releases, or a refusal. Never a silent empty list."""
    status, body = api_get(f"{slug}/releases?per_page=100")
    if status is HTTPStatus.NOT_FOUND:
        raise BaselineError(
            f"the releases API says {slug} does not exist. That is a wrong subject, "
            "not an absence of releases; refusing to read it as one."
        )
    if status is not HTTPStatus.OK:
        excerpt = " ".join(body.split())[: len(API_ROOT + API_ROOT)]
        raise BaselineError(
            f"the releases API answered {status} for {slug}, which states neither "
            f"presence nor absence, so the tier is unproven: {excerpt!r}"
        )
    try:
        payload = json.loads(body)
    except json.JSONDecodeError as error:
        raise BaselineError(f"the releases API for {slug} did not answer with JSON: {error}") from error
    if not isinstance(payload, list):
        raise BaselineError(f"the releases API for {slug} answered {type(payload).__name__}, not a list")
    return [entry["tag_name"] for entry in payload if not entry.get("draft")]


def repository_tag_names(slug: str) -> list[str]:
    """Tag names the API serves for one repository, or a refusal.

    Same client, same credential, same JSON-list handling as the releases probe, so it
    is the strongest control available for that probe on a repository which -- being on
    a tag tier -- has no releases of its own to recognise.
    """
    status, body = api_get(f"{slug}/tags?per_page=100")
    if status is not HTTPStatus.OK:
        excerpt = " ".join(body.split())[: len(API_ROOT + API_ROOT)]
        raise BaselineError(
            f"the tags API answered {status} for {slug}, so this probe cannot read the "
            f"repository it is asking about: {excerpt!r}"
        )
    try:
        payload = json.loads(body)
    except json.JSONDecodeError as error:
        raise BaselineError(f"the tags API for {slug} did not answer with JSON: {error}") from error
    if not isinstance(payload, list):
        raise BaselineError(f"the tags API for {slug} answered {type(payload).__name__}, not a list")
    return [entry["name"] for entry in payload if entry.get("name")]


def assert_probe_can_see_this_repository(slug: str, root: Path) -> None:
    """Fail-closed twin, on a subject this job's own credential can reach.

    "Unproven" is also what a broken expression produces, so the probe must prove it can
    still recognise a fact that certainly holds. This repository serves no releases --
    that is exactly why its tier is a tag -- so it cannot control the releases probe on
    itself with a release. What it can demand is everything that probe depends on and
    shares, under its own slug:

      the API names THIS repository back. A permission refusal, a rate-limit page or an
      expired token cannot fake `full_name`, and a question about our own slug cannot be
      a wrong subject -- which is the failure class neither a control nor content-reading
      catches when the control is somebody else's repository.

      while the remote holds tags, the API's list endpoint shows some too. Authorised
      silence on our own slug yields an empty list while `git ls-remote` still lists
      eight, and that disagreement between two transports is the state a control exists
      to catch. It also exercises the list handling the releases probe uses, which
      naming alone would not.

    A repository with no tags at all is not failed for it: there the tier is head, and
    demanding tags would invent the mirror defect -- a gate that can never pass.
    """
    status, body = api_get(slug)
    if status is not HTTPStatus.OK:
        raise BaselineError(
            f"the API answered {status} for {slug}, so this probe cannot read the "
            "repository it is asking about, and every absence it reports is unproven"
        )
    try:
        payload = json.loads(body)
    except json.JSONDecodeError as error:
        raise BaselineError(f"the API for {slug} did not answer with JSON: {error}") from error
    named = payload.get("full_name", "") if isinstance(payload, dict) else ""
    if named.lower() != slug.lower():
        raise BaselineError(
            f"the API did not name {slug} back -- it answered {named!r} -- so this probe "
            "is not reading the repository it believes it is reading"
        )
    over_git = remote_tags(root)
    if not over_git:
        return
    over_api = repository_tag_names(slug)
    if not over_api:
        raise BaselineError(
            f"{REMOTE} lists {len(over_git)} tags for {slug} but the API's list endpoint "
            "shows none, so it is silent about a fact that certainly holds and no "
            "absence it reports can be believed"
        )


def version_key(tag: str) -> tuple:
    match = SEMVER.match(tag)
    if match is None:
        return ()
    return tuple(int(part) for part in match.group("core").split("."))


def newest(tags: list[str]) -> str | None:
    ranked = [tag for tag in tags if version_key(tag)]
    if not ranked:
        return None
    return max(ranked, key=version_key)


def remote_tags(root: Path) -> list[str]:
    """Tags as the remote holds them.

    Read from the remote, never from `git tag --list`: `actions/checkout@v4`
    fetches no tags, so a local listing is empty on a runner whatever the remote
    holds, and a tier probe built on it concludes the bottom tier is best exactly
    when a better one exists.
    """
    listing = run(["git", "-C", str(root), "ls-remote", "--tags", REMOTE])
    found = []
    for line in listing.splitlines():
        parts = line.split()
        if len(parts) < len(("sha", "ref")):
            continue
        ref = parts[-ONE]
        prefix = "refs/tags/"
        if not ref.startswith(prefix):
            continue
        name = ref[len(prefix):]
        if name.endswith("^{}"):
            name = name[: -len("^{}")]
        if name not in found:
            found.append(name)
    return found


def assert_tag_agrees_with_remote(root: Path, tag: str) -> None:
    """The local tag must name the same commit the remote does.

    A Swift manifest has no version field, so the usual "does the tree declare
    the version the tag claims" check has nothing to read. This is the available
    substitute, and it is the one that matters on a runner: it fails closed when
    tags were never fetched, and it catches a local tag that was moved.
    """
    local = run(["git", "-C", str(root), "rev-parse", f"{tag}^{{commit}}"]).strip()
    listing = run(["git", "-C", str(root), "ls-remote", REMOTE, f"refs/tags/{tag}"])
    remote_objects = {line.split()[ZERO] for line in listing.splitlines() if line.split()}
    if not remote_objects:
        raise BaselineError(f"the remote does not serve tag {tag}, so it is not an artifact anyone resolved")
    peeled = set()
    for obj in remote_objects:
        peeled.add(run(["git", "-C", str(root), "rev-parse", f"{obj}^{{commit}}"]).strip())
    if local not in peeled:
        raise BaselineError(
            f"tag {tag} is {local} here but {sorted(peeled)} at the remote; refusing to "
            "measure a baseline against a tag whose identity is not settled"
        )


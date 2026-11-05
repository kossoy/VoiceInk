"""Check an upstream merge using the manifest and script from the trusted fork base.

This detects clean merges that overwrite fork-owned files or remove app hooks.
It complements compiled tests; it does not prove runtime behavior from strings.
"""
import argparse
import fnmatch
import json
from pathlib import Path
import subprocess
import sys


def git(*arguments):
    return subprocess.check_output(["git", *arguments])


def check(base, candidate, manifest):
    git("cat-file", "-e", f"{base}^{{commit}}")
    git("cat-file", "-e", f"{candidate}^{{commit}}")
    # Include both sides of a rename, including a move out of a protected directory.
    changed = git("diff", "--no-renames", "--name-only", "-z", base, candidate, "--").decode().split("\0")
    errors = []
    for path in filter(None, changed):
        if any(fnmatch.fnmatchcase(path, pattern) for pattern in manifest["protected_paths"]):
            errors.append(f"upstream changed fork-owned path: {path}")
    for path, snippets in manifest["required_snippets"].items():
        try:
            content = git("show", f"{candidate}:{path}").decode()
        except subprocess.CalledProcessError:
            errors.append(f"fork integration file missing: {path}")
            continue
        for snippet in snippets:
            if snippet not in content:
                errors.append(f"fork hook missing in {path}: {snippet}")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--manifest", type=Path, default=Path(__file__).with_name("fork-contracts.json"))
    args = parser.parse_args()
    errors = check(args.base, args.candidate, json.loads(args.manifest.read_text()))
    for error in errors:
        print(f"::error::{error}", file=sys.stderr)
    if errors:
        print("Fork contracts failed; main and the upstream mirror must remain unchanged.", file=sys.stderr)
        return 1
    print("Fork-owned paths and integration hooks preserved.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

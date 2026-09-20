#!/bin/sh
# Privacy gate: the owner's security preset must never enter this repository.
#
# Why this file exists. The preset's persona, its authorization registry and its
# allowlists are private property -- the registry alone names every client and
# every authorized target. Its sources, its packed tarball and its notes live in
# a sibling directory next to this checkout (phone-diag/) and reach the device
# over USB, so an ordinary `git add -A` run from this root structurally cannot
# reach them. This gate turns that structural fact into an enforced one: if a
# preset-shaped path ever becomes tracked, the build stops loudly instead of
# publishing it. .gitignore keeps the same shapes out of the index; this script
# is the belt to that pair of braces, because an ignore rule is silent and this
# is not.
#
# Run it as:  sh scripts/privacy-guard.sh
# Exit 0 = clean.  Exit 1 = at least one tracked path looks like preset content.
#
# The patterns are deliberately narrow: upstream iSH carries
# ish-arm64/kernel/personality.h (the Linux personality(2) syscall), which a
# loose /persona/ match would flag forever. Names here must not collide with
# anything the fork legitimately tracks.

set -u

# preset dirs | its .mjs tools | its allowlist | persona/registry docs |
# its composition file | its packed tarball | this profile's own name
PATTERN='(^|/)(preset-security|security-preset|\.agent-presets)/|(^|/)(scope-guard|scope-tool|new-project|backup-file)[^/]*\.mjs$|(^|/)infra-allowlist\.txt$|(^|/)(persona|authorization)[^/]*\.md$|(^|/)agent\.cordis\.yml$|(^|/)dsh-preset[^/]*\.tar\.gz$|(^|/)attack-specialist[^/]*\.md$'

root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "privacy-guard: not inside a git work tree" >&2
    exit 1
}
cd "$root" || exit 1

bad=$(git ls-files | grep -Ei "$PATTERN" || true)

if [ -n "$bad" ]; then
    echo "privacy-guard: BLOCKED -- these tracked paths look like security-preset content:" >&2
    printf '%s\n' "$bad" | sed 's/^/  /' >&2
    echo "privacy-guard: untrack them (git rm --cached) and scrub history before pushing." >&2
    exit 1
fi

count=$(git ls-files | wc -l | tr -d ' ')
echo "privacy-guard: clean -- no preset content is tracked ($count files checked)"

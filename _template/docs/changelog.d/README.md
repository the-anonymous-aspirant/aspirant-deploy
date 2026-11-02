# Changelog fragments

`docs/CHANGELOG.md` is not edited in a feature PR. Each PR adds **one file**
here, and `scripts/changelog.sh collect` folds the files into the changelog on
a PR of its own, so no two PRs touch the same file (platform convention:
[Philosophy → Changelog](../../../DEVELOPMENT_PHILOSOPHY.md#changelog)).

## Filename

`<YYYY-MM-DD>-<task>[-<slug>].md` — the day the PR is opened, the system_3
task id (or the branch slug when there is none), and an optional lowercase
slug when one task opens several PRs on the same day. The entry renders under
the `### YYYY-MM-DD` heading for that date, created when missing.

## Body

One or more `- ` bullets, continuation lines indented two spaces, past tense,
what changed rather than what you did, no heading, no trailing whitespace, a
final newline. The script places it.

## Commands

    sh scripts/changelog.sh check     # validates the fragments; run before pushing
    sh scripts/changelog.sh render    # prints CHANGELOG.md with the fragments merged in
    sh scripts/changelog.sh collect   # writes that rendering to CHANGELOG.md and deletes the fragments

`collect` runs only on a PR of its own, at most one open at a time.

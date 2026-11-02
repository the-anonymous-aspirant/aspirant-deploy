# Changelog fragments

`docs/CHANGELOG.md` is not edited in a feature PR. Each PR adds **one file**
here, and `scripts/changelog.sh collect` folds the files into the changelog on
a PR of its own. Two PRs then never touch the same file, so neither conflicts
with the other. Before this, every PR added its bullet under the day's
`### YYYY-MM-DD` heading in the one file; on 2026-11-01 PRs #110, #111 and
#112 each passed verify and went CONFLICTING there (system_3 #9455, #9477).

## Filename

`<YYYY-MM-DD>-<task>[-<slug>].md`

- `YYYY-MM-DD`: the day the PR is opened. The entry renders under the
  `### YYYY-MM-DD` heading for this date, and the heading is created when the
  changelog has none for that day.
- `task`: the system_3 task id the PR is linked to, for example `9477`. A PR
  with no task uses its branch slug.
- `slug`: optional, lowercase `a-z0-9-`, when one task opens several PRs on
  the same day.

Example: `2026-11-02-9477.md`

## Body

The entry exactly as it would have gone under the day's heading in
`docs/CHANGELOG.md`: one or more `- ` bullets, continuation lines and
sub-bullets indented two spaces, past tense, what changed rather than what you
did, no heading, no trailing whitespace, a final newline. The script places
it; the bullets of one day stay contiguous, newest fragment first.

    - Area: what changed (system_3 #NNNN). Why, and what the operator sees
      now. Keep the git log for the details.

## Commands

    sh scripts/changelog.sh check     # validates the fragments; run before pushing
    sh scripts/changelog.sh render    # prints CHANGELOG.md with the fragments merged in, newest first
    sh scripts/changelog.sh collect   # writes that rendering to CHANGELOG.md and deletes the fragments

`collect` runs only on a PR of its own (a chore titled "Collect changelog
fragments"), at most one open at a time. Tests: `sh tests/changelog_unit.sh`.

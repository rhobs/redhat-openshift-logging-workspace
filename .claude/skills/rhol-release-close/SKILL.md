---
name: rhol-release-close
description: >
  Use when the user asks to close, ship, or release a RHOL z-stream release in Jira after its
  ART shipment MR merges — e.g. "close 6.5.4", "release Logging 6.5.4". Takes a shipment MR
  URL or bare version number (finds the MR by title), extracts the prod errata URL from the
  shipment image YAML, and updates the Logging X.Y.Z Jira release: description, release date,
  released status, and offers to close the release tracking issue. Optionally creates the
  next z-stream version (start date = release date + 1 day) and bumps the operator versions
  (CLO, loki-operator) on their release-X.Y branches via rhol-version-incrementer.
---

# RHOL Release Close

Close out a RHOL z-stream release in Jira once its ART shipment MR has merged: put the errata
URL on the release, set the release date, and mark the version released.

## Role

You are closing the Jira **project version** named `Logging <X.Y.Z>` in project LOG — the
version, not an issue, holds the description, release date, and released status.

## Inputs

The user gives either a **shipment MR URL** in the `ocp-shipment-data` repository (e.g.
`https://gitlab.cee.redhat.com/hybrid-platforms/art/ocp-shipment-data/-/merge_requests/1159`)
or a **bare version number** ("close 6.5.4" — the MR is found by its title). If neither is
given, ask — do not guess a version or construct an MR URL.

## Prerequisites

- Network access to `gitlab.cee.redhat.com` (anonymous read works from the corp network; on
  401/403/404 tell the user rather than retrying)
- Atlassian MCP tools; cloudId for redhat.atlassian.net:
  `2b9e35e3-6bd3-4cec-b838-f4249ee02432`

## Instructions

### Step 1 — Extract the shipment data

Run the bundled script with the MR URL or version; it finds the shipment MR (searching
opened, then merged, then all MRs by the exact title `Shipment for openshift-logging
<version> (ship date: ...)`), verifies the MR state, parses the version and ship date, and
extracts the prod advisory URL from the image advisory YAML (not the `.fbc.` files, not the
`stage` environment). It exits non-zero with a clear error on any mismatch:

```bash
eval "$(bash "$SKILL_DIR/scripts/extract-shipment.sh" <mr-url-or-version>)"
echo "$MR_IID $MR_STATE $VERSION $RELEASE_DATE $ERRATA_URL"
```

`$SKILL_DIR` is this skill's base directory. The script prints `MR_IID`, `MR_STATE`,
`VERSION`, `RELEASE_DATE` (ISO), and `ERRATA_URL`.

If `MR_STATE` is `opened` (not `merged`), warn the user the MR has not merged yet and get
explicit confirmation before proceeding — do not close the release early on your own
judgment.

### Step 2 — Find the Jira release

The Jira version name is `Logging <version>`. Look it up with `getJiraProjectVersions`
(executeRead, projectIdOrKey `LOG`, query `Logging <version>`) and keep its `versionId`.

If the version does not exist, stop — do not create it (`rhol-release-plan` owns creation).
If it is already `released: true`, report that and ask the user before overwriting.

### Step 3 — Summarize and confirm

Present a summary and get the user's confirmation (AskUserQuestion) before writing: the
release version name and versionId; the errata URL that will become the description; the
release date; that the version will be marked released.

The established description convention is the **bare errata URL** — no label, no extra prose
(see released versions like `Logging 6.5.3` or `Logging 6.5.2` for examples).

### Step 4 — Update the release

Apply all three changes in one `manageJiraProjectVersion` call (executeDestructive),
action `update`:

```json
{
  "cloudId": "2b9e35e3-6bd3-4cec-b838-f4249ee02432",
  "action": "update",
  "versionId": "<versionId>",
  "description": "<errata URL>",
  "releaseDate": "<YYYY-MM-DD>",
  "released": true
}
```

`released` must be a real boolean. Use action `update` (not `release`) so the description and
release date land in the same call. Only pass `moveUnfixedIssuesTo` if the user explicitly
asks to sweep unresolved issues into a later version — never decide that yourself.

### Step 5 — Report

Report what was written: version name, errata URL, release date, released status. Mention
anything skipped or failed (unmerged MR, missing version, already released) rather than
silently omitting it.

### Step 6 — Offer to create the next z-stream release

Offer to create the next z-stream release version in the LOG project, e.g. closing `6.5.4` →
create `Logging 6.5.5`. Do not create it unasked — ask first (AskUserQuestion), then:

- **Version name:** `Logging <X.Y.(Z+1)>` — bump only the patch component. If the user asks
  for a different version, use theirs.
- **Start date:** the closed release's **release date + 1 day**.
- **Release date:** leave unset — it comes from the next release's planning (the
  `rhol-release-plan` skill owns the full release ticket workflow; this step only creates
  the Jira version).

Before creating, check the version does not already exist (`getJiraProjectVersions`,
query `Logging <new version>`); if it does, report and skip. Create with
`manageJiraProjectVersion` (executeDestructive), action `create`: `projectIdOrKey: "LOG"`,
`name: "Logging <X.Y.(Z+1)>"`, `startDate: "<release date + 1 day>"` (same cloudId). Then
report the new version name, versionId, and start date.

### Step 7 — Offer to bump the operator versions for the new release

After creating the next z-stream release (or when the user asks to "bump the versions" for
it), offer to bump the **operators only** — cluster-logging-operator and loki-operator —
using the **`rhol-version-incrementer`** skill. Do not bump unasked, and do not bump the
other components (LFME, eventrouter) as part of release close.

Both operators have a branch per z-stream: the bump for an `X.Y.Z` release runs against the
matching `release-X.Y` branch of the operator's repo, and the PR targets that branch (never
`main`):

| Operator | Repository | Bump branch (for X.Y.Z) |
|---|---|---|
| cluster-logging-operator | `github.com/openshift/cluster-logging-operator` | `release-X.Y` |
| loki-operator | Red Hat fork `github.com/openshift/loki` (**not** the workspace `loki/` clone, which tracks `grafana/loki`) | `release-X.Y` (same stream as the release) |

Also bump **ocp-build-data** (per
[openshift-eng/ocp-build-data#13169](https://github.com/openshift-eng/ocp-build-data/pull/13169)):
on its per-stream branch `logging-X.Y`, edit the top-level `group.yml` `version:` line to the
target version — nothing else changes. There is no workspace clone: fetch the branch into a
worktree and PR against `logging-X.Y` (not `main`). Commit message and PR title:
`chore: update logging version to <X.Y.Z>`.

Notes:

- The target version equals the new release's `<X.Y.Z>` for both operators and the
  ocp-build-data group — the two operators do **not** stream independently; both are bumped
  to the same version on their same-stream `release-X.Y` branches.
- Check out a worktree of the matching `release-X.Y` branch and pass it as the bump script's
  repo-path; create PRs with `--base release-X.Y`. Dry-run first, show the user the diff, and
  get confirmation before any commit/push/PR.

### Step 8 — Offer to close the release tracking issue (always last)

Only after everything else is done, offer to close the LOG **release tracking issue**
(summary `OpenShift Logging z-stream: <version>`, from `rhol-release-plan`). If its key is
not already known, ask the user for it — or search `project = LOG AND summary ~ "OpenShift
Logging z-stream: <version>"` with `searchJiraIssuesUsingJql`. Never guess an issue key.
With confirmation, transition it to **Closed**: find the transition whose `to.name` is
`Closed` via `listJiraIssueTransitions` (executeRead), apply it with `transitionJiraIssue`,
and report the final status.

## Common Mistakes

- Reading the advisory URL from `stage` instead of `prod`, or from an `.fbc.` file instead of
  the `.image.` file (the bundled script handles this — don't hand-roll it)
- Treating the release as a Jira issue — it is a project version; `editJiraIssue` and
  `transitionJiraIssue` do not apply to it
- Marking the version released before the MR has merged without warning the user and getting
  confirmation; or overwriting an already-released version without asking
- Writing to Jira without showing the user the summary first
- Creating the next z-stream version unasked, or giving it a release date
- Bumping LFME or eventrouter as part of release close — only the two operators (on their
  `release-X.Y` branch) and the ocp-build-data group (on its `logging-X.Y` branch) are
  bumped; never PR these against `main`
- Running the loki-operator bump against the workspace `loki/` clone (it tracks grafana/loki),
  or bumping the two operators to different versions — they always move together to the
  release's `<X.Y.Z>` on their same-stream `release-X.Y` branches

---
name: rhol-qe-trigger-e2e-tests
description: >
  Use when the user asks to trigger, kick off, or run the QE e2e integration tests
  (prow jobs) for a Red Hat OpenShift Logging release verification — e.g. "trigger the
  e2e jobs for 6.5", "run the release e2e tests", "kick off QE integration for 6.6".
  Authenticates to the CI cluster via CLI only (no console/SSO interaction), obtains
  the GANGWAY API token, triggers the matching prow jobs through the gangway API,
  resolves each job's URL, and reports job IDs and URLs in a table.
---

# rhol-qe-trigger-e2e-tests

Trigger the RHOL QE e2e integration prow jobs for release verification via the
GANGWAY API, using only command-line authentication.

## Role

You are a release engineer kicking off QE e2e verification for a RHOL release. You
trigger the correct set of prow jobs for the requested release stream, confirm each
trigger succeeded, and give the user a list of job IDs and URLs they can watch.

## Inputs

- **release version** (required) — the logging release stream, e.g. `6.5`, `6.6`.
  Accept forms like "6.6", "logging 6.0", "the 6.5 release". Map to the job list below.
- **job name** (optional) — if the user names a specific prow job, trigger only it.
- **all streams** — if the user asks for "all jobs" or does not name a version, ask
  which stream(s) they want; do not trigger every stream by default.

If the requested version has no entry in the job table below, stop and tell the user
the job names are unknown for that stream — do not guess or construct job names.

## Important constraints

- **Never interact with the web console or SSO.** Every manual step that mentions the
  console has a CLI equivalent in this skill — use it.
- **Never print or persist the GANGWAY token** in files, reports, or command output
  shown to the user beyond what `oc`/`curl` inherently display. Keep it in a shell
  variable for the session only.
- **Triggering jobs is an outward-facing action.** Before the first POST, state which
  jobs you are about to trigger and how many, and get the user's go-ahead if the
  request was anything less than an explicit "trigger them".

## Prerequisites

- `oc` — authenticated (or authable) against the CI cluster
  `api.ci.l2s4.p1.openshiftapps.com`
- `curl`, `jq`
- cluster-reader-ish access to the `ocp-qe-logging-team` namespace (to extract
  `secret/api-token-secret`)

## Instructions

### Step 0 — Determine the GANGWAY token

All console/SSO steps from the manual procedure are replaced by this step. Try every
CLI avenue to obtain a working token yourself before asking the user for anything.

1. Try the current `oc` login:
   ```sh
   oc whoami --show-server 2>/dev/null
   ```
   If the server is `https://api.ci.l2s4.p1.openshiftapps.com:6443` and `oc whoami`
   succeeds, use it as-is.
2. If logged into a different cluster or not logged in, look for a CI kubeconfig the
   user may already have — check `~/.kube/` for config files whose `server:` points at
   `api.ci.l2s4.p1.openshiftapps.com` (e.g. `grep -l "ci.l2s4.p1" ~/.kube/*`), and
   known workspace files like `art.kubeconfig`. For each candidate, try:
   ```sh
   KUBECONFIG=<path> oc whoami
   ```
3. With whichever credential works, attempt to extract the GANGWAY token (Step 1
   below). Extraction counts as part of "determining the token" — a login that cannot
   read `secret/api-token-secret` is not a working credential; keep trying other
   candidates.
4. Only if no candidate yields both a valid login and a successful token extraction —
   or extraction fails with an auth/forbidden error — ask the user to log in
   themselves in this session:
   > Please type `! oc login https://api.ci.l2s4.p1.openshiftapps.com:6443 --token=<your-ci-token>`
   > (token from your SSO "Copy login command" on the CI console — the one manual step
   > that has no CLI-only source).
   Then redo Step 1. Do not attempt to guess or reuse tokens found elsewhere on disk.

### Step 1 — Extract the GANGWAY token

```sh
GANGWAY_API_TOKEN=$(oc -n ocp-qe-logging-team extract secret/api-token-secret --to=- 2>/dev/null)
```

- The `--to=-` form prints the secret value to stdout with no files written.
- If extraction fails (forbidden/not found) with every candidate credential, fall back
  to asking the user for a login (Step 0, item 4). As a secondary fallback, the user
  may instead supply the prow token documented by QE (the "prow token" note in the
  manual procedure) — ask them where to find it rather than guessing a location.
- Verify it is non-empty before continuing; abort with a clear message if it is.

### Step 2 — Trigger the jobs

For each prow job for the requested release stream (see job table), POST to gangway:

```sh
curl -sS -X POST \
  -d '{"job_execution_type": "1"}' \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${GANGWAY_API_TOKEN}" \
  "https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions/${PROW_JOB_NAME}"
```

- Trigger jobs one at a time and record each response (job_id, job_url).
- Run these from a single shell session so `GANGWAY_API_TOKEN` stays in scope; re-run
  Step 1 if the session was reset.
- If a POST returns an auth error, the token is stale/expired — redo Steps 0–1.
- On other failures that look like infra or cluster-provisioning problems (5xx,
  timeouts), retry the POST once for that job. If it fails again, report it and move
  on to the other jobs — one failed trigger does not block the rest.

### Step 3 — Resolve job URLs

If a response has an empty `job_url`, fetch it by job_id:

```sh
curl -sS -X GET \
  -H "Authorization: Bearer ${GANGWAY_API_TOKEN}" \
  "https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions/${job_id}"
```

Parse the `job_url` from the response.

### Step 4 — Report

Present a table and nothing else needs committing:

| Job | Job ID | URL |
|-----|--------|-----|
| `periodic-ci-…-f999-logging` | 12345 | https://… |

Then state plainly: which jobs triggered successfully, which failed to trigger (with
the error), and that re-triggering a failed job is safe. Do not monitor or poll job
status unless asked.

## Prow job table

Logging 6.0:
- periodic-ci-openshift-openshift-tests-private-release-4.14-amd64-nightly-openshift-logging-6.0-gcp-ipi-sdn-fips-f60-logging
- periodic-ci-openshift-openshift-tests-private-release-4.16-amd64-stable-openshift-logging-6.0-azure-ipi-oidc-amd-f14-logging
- periodic-ci-openshift-openshift-tests-private-release-4.17-multi-stable-openshift-logging-6.0-aws-ipi-proxy-sts-mixarch-f14-logging

Logging 6.2:
- periodic-ci-openshift-openshift-tests-private-release-4.17-multi-stable-openshift-logging-6.2-aws-ipi-arm-f999-logging
- periodic-ci-openshift-openshift-tests-private-release-4.18-multi-stable-openshift-logging-6.2-azure-ipi-arm-f999-logging
- periodic-ci-openshift-openshift-tests-private-release-4.19-amd64-stable-openshift-logging-6.2-gcp-ipi-proxy-oidc-amd-f999-logging

Logging 6.5:
- periodic-ci-openshift-openshift-tests-private-release-4.20-arm64-stable-openshift-logging-6.5-azure-ipi-arm-f999-logging
- periodic-ci-openshift-openshift-tests-private-release-4.21-multi-stable-openshift-logging-6.5-gcp-ipi-arm-fips-f999-logging
- periodic-ci-openshift-openshift-tests-private-release-4.22-multi-nightly-openshift-logging-6.5-aws-ipi-amd-f999-logging

Logging 6.6:
- periodic-ci-openshift-openshift-tests-private-release-4.21-arm64-stable-openshift-logging-6.6-azure-ipi-arm-f999-logging
- periodic-ci-openshift-openshift-tests-private-release-4.22-multi-stable-openshift-logging-6.6-gcp-ipi-arm-fips-f999-logging
- periodic-ci-openshift-openshift-tests-private-release-4.23-multi-nightly-openshift-logging-6.6-aws-ipi-amd-f999-logging

Logging 6.6 (new E2E repo, split clo/loki):
- periodic-ci-openshift-eng-openshift-logging-e2e-tests-main-amd64-stable-openshift-logging-6.6-aws-ipi-f14-logging-clo
- periodic-ci-openshift-eng-openshift-logging-e2e-tests-main-amd64-stable-openshift-logging-6.6-aws-ipi-f14-logging-loki

## TBD — pinning jobs to specific ART-built FBC and images

The current gangway trigger payload is only `{"job_execution_type": "1"}` and carries
no parameter slot for an FBC pullspec or image set; the jobs test whatever the
catalog/stage provides. When QE documents how to pass ART-built FBC/images explicitly
(e.g. extra gangway payload fields or prow job parameters), add it here as a new step
between Step 1 and Step 2, and record the payload shape. Until then, do not invent
payload fields — the API will ignore or reject them.

## Common mistakes

- **Using the console** — the manual procedure's SSO/clipboard steps exist only as
  background; this skill is CLI-only.
- **Writing the token to a file** — `oc extract secret/... --to=-` prints to stdout;
  never use `--to=<dir>`, and never echo the token into a report.
- **Retrying non-infra failures** — only infra/provisioning-looking failures warrant a
  re-trigger; auth errors mean the token is stale, and 4xx validation errors mean the
  job name is wrong (check the table).
- **Guessing job names for an unlisted release stream** — stop and ask.

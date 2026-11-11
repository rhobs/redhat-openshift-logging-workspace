---
name: release-issue-auditor
description: >
  Audits JIRA issues for an upcoming release to ensure statuses, release notes, 
  and PRs meet code-freeze requirements. Automatically expands version streams, 
  validates custom fields, checks PR /hold labels via GitHub CLI, and outputs a triage report.
  Use when auditing release readiness for code freeze or checking release criteria.
argument-hint: '6.2.13'
---

# Audit Release Issues for Code-Freeze

## Overview

Audits JIRA issues for an upcoming OpenShift Logging release to verify readiness for QE, proper release note configuration, sprint assignment, and `/hold` labels on open PRs prior to code-freeze.

---

## Workflow

### Step 1: Parse Version & Construct JQL

If target version is not provided, prompt the user (e.g., `6.2.13` or `6.2.z`).

**Version Normalization Rules:**
1. Strip any existing `"Logging "` prefix and extract base stream `X.Y` and patch `Z` (or `z`).
2. Expand targets:
    - Shorthand patch `X.Y.Z` (e.g., `6.2.13`) -> `"Logging X.Y.Z"`, `"Logging X.Y.z"`
    - Stream `X.Y.z` (e.g., `6.2.z`) -> `"Logging X.Y.z"`
3. If input cannot be parsed into `X.Y.Z` or `X.Y.z`, prompt user for clarification before proceeding.

**JQL Query:**
```text
project = "OpenShift Logging" AND type in (Bug, Task, Story, Vulnerability, Weakness) AND status not in (New, "To Do", Assigned, "In Progress") AND resolution is EMPTY AND fixVersion in (<TARGET_VERSIONS>) ORDER BY key ASC
```
*(Note: `resolution is EMPTY` correctly targets all unresolved issues).*

---

### Step 2: Fetch Issues & Field Schema

Execute search using `mcp__atlassian__searchJiraIssuesUsingJql`. If total issues exceed 100 (`total > maxResults`), paginate (`startAt += maxResults`) until all issues are retrieved.

**Field Mapping & Extraction Table:**

| Semantic Field | Jira Field Key | Extraction Logic |
| :--- | :--- | :--- |
| **Key** | `key` | String (e.g., `"LOG-9940"`) |
| **Summary** | `summary` | String |
| **Status** | `status` | Case-insensitive name (`status.name`) |
| **Issue Type** | `issuetype` | Name string (`issuetype.name`) |
| **Assignee** | `assignee` | Display name (`assignee.displayName`) or `"Unassigned"` |
| **Labels** | `labels` | Array of strings (check for `no-rn`) |
| **Security** | `security` | `null` = public; non-null = private/restricted |
| **Issue Links** | `issuelinks` | Clone/relational links (used for clone checks) |
| **Fix Versions** | `fixVersions` | Array of version names |
| **RN Text** | `customfield_10783` | Text content (check for non-empty string) |
| **RN Type** | `customfield_10785` | Value string (`customfield_10785.value` or string) |
| **RN Status** | `customfield_10807` | Workflow state (`customfield_10807.value` or string) |
| **Sprint** | `customfield_10020` / `sprint` | Array/object (check if assigned to active release sprint) |

*Do NOT attempt dynamic field discovery; use these static IDs.*

**MCP Call:**
```bash
mcp__atlassian__searchJiraIssuesUsingJql \
  --cloudId "https://redhat.atlassian.net" \
  --jql "$CONSTRUCTED_JQL" \
  --fields '["key","summary","status","issuetype","assignee","labels","security","issuelinks","fixVersions","customfield_10783","customfield_10785","customfield_10807","customfield_10020"]' \
  --maxResults 100
```

---

### Step 3: Issue Validation Rubric

Evaluate each retrieved issue against the following rules (status matches are case-insensitive):

#### 1. Vulnerability / CVE Issues (`issuetype == "Vulnerability"`)
- **RN Type:** MUST be `"CVE - Common Vulnerabilities and Exposures"`.
- **RN Text:** Not required.
- **Security:** Allowed to be set (confidentiality expected for CVEs).
- **Rule:** Flag in **Section 2** if RN Type is anything else.

#### 2. Non-CVE Issues (Bug, Task, Story, Weakness)
- **Release Notes:** Must satisfy at least ONE of:
    - Non-empty RN Text (`customfield_10783`) AND RN Type is set, OR
    - Contains `no-rn` label, OR
    - RN Type equals `"Release Note Not Required"`.
- **Rule:** Flag in **Section 4** if none of the above are met.

#### 3. Status Check
Issues must be ready for QE pickup or already QE'd:
- **Bugs:** Allowed statuses: `MODIFIED`, `ON_QA`, `VERIFIED`.
- **Tasks / Stories / Weaknesses:** Allowed statuses: `REVIEW`, `RELEASE PENDING`, `VERIFIED`.
- **Action Required:** Flag any issue in `CODE REVIEW` or `POST` in **Section 5**.
    - For `POST`: Check linked PR state. If PR is merged, flag as "Needs transition to Modified/Review (PR already merged)". If PR is open, treat as "In progress (PR open)".
    - Any issue not in allowed or review statuses is flagged as invalid status.

#### 4. Private / Restricted Issue Check (`security != null` and `issuetype != "Vulnerability"`)
- Private issues cannot appear directly in public release notes or errata.
- Must satisfy ONE of:
    - Has `no-rn` label, OR
    - Linked to a public clone issue (`security == null`) that contains the release note.
- **Rule:** Flag in **Section 6** if private without `no-rn` or public clone. Remediation: Create public issue first, clone from it, and assign release notes to the clone.

#### 5. GitHub PR Hold Check (`CODE REVIEW` or `POST` issues)
For flagged issues in `CODE REVIEW` or `POST`:
1. Call `mcp__atlassian__getJiraIssueRemoteIssueLinks` per issue.
2. Extract URLs matching `https://github.com/[^/]+/[^/]+/pull/\d+`.
3. If no GitHub PR is linked, flag: `"No linked PR found for issue in Code Review/POST"`.
4. Deduplicate PR URLs across issues to avoid redundant CLI executions.
5. For each unique open PR, query via GitHub CLI:
   ```bash
   gh pr view <PR_URL> --json labels,state -q '{labels: [.labels[].name], state: .state}'
   ```
6. **Evaluation:**
    - **Open PR:** Must have `do-not-merge/hold` label. Flag in **Section 7** if missing.
    - **Merged PR:** No hold required; flag parent Jira issue in **Section 5** if status was not transitioned.
    - **Error Handling:** If `gh` fails (auth/network/not found), flag PR with error state for manual review; do not abort execution.

#### 6. Multi-Release & Sprint Validation (Informational)
- **Multi-Release:** If `fixVersions` spans multiple release branches (e.g., `6.4.z` and `6.5.z`), verify separate cloned issues exist per release.
- **Sprint:** Check if the issue is assigned to the current release sprint. Flag unassigned issues in the report summary.

---

### Step 4: Generate & Save Audit Report

1. Write the full Markdown report to file: `RELEASE_AUDIT_<VERSION>.md` (e.g., `RELEASE_AUDIT_6.2.13.md`).
2. Provide clickable Jira bulk query links for any non-empty flagged section:
   `https://redhat.atlassian.net/issues/?jql=key%20in%20(<COMMA_SEPARATED_KEYS>)`
3. Output the final summary table and blockers to the user interface upon completion.

---

## Audit Report Output Format

```markdown
# Release Audit Report: Logging <TARGET_VERSIONS>

**All audited issues:** [View in Jira](<URL_ENCODED_JQL_LINK>)

## 1. CVE/Vulnerability Issues
**Count:** <N>
- Table or list: Key, Summary, Assignee, Status

## 2. CVEs with Wrong Release Note Type
**Count:** <N>
[View Issues in Jira](https://redhat.atlassian.net/issues/?jql=key%20in%20(...)) *(omit link if Count is 0)*
- List of CVEs with incorrect RN Type (or "None ✅")

## 3. Other Issues (Bug, Task, Weakness, etc.)
**Count:** <N>
| Key | Type | Assignee | Status | RN Type | Sprint |
| :--- | :--- | :--- | :--- | :--- | :--- |

## 4. Issues Missing Release Notes
**Count:** <N> ❌ BLOCKING
[View Issues in Jira](https://redhat.atlassian.net/issues/?jql=key%20in%20(...)) *(omit link if Count is 0)*
- Criteria: Non-CVE lacking RN Text, 'no-rn' label, and RN Type != 'Release Note Not Required'
| Key | Type | Assignee | Status | Action Required |

## 5. Issues with Wrong Status
**Count:** <N> ❌ BLOCKING
[View Issues in Jira](https://redhat.atlassian.net/issues/?jql=key%20in%20(...)) *(omit link if Count is 0)*
- Issues in "Code Review", "POST", or non-QE ready states
| Key | Status | Linked PR | PR State | Required Transition / Action |

## 6. Private Issues with Security Level (Non-CVE)
**Count:** <N>
[View Issues in Jira](https://redhat.atlassian.net/issues/?jql=key%20in%20(...)) *(omit link if Count is 0)*
- Non-CVE issues where `security != null` lacking `no-rn` or public clone.
- If Count is 0: "No private issues found ✅"

## 7. PRs Missing /hold Label
**Count:** <N> ❌ BLOCKING
[View Issues in Jira](https://redhat.atlassian.net/issues/?jql=key%20in%20(...)) *(omit link if Count is 0)*
| PR URL | PR State | Linked Jira Issue | Assignee | Status |
- If Count is 0: "All open PRs have /hold label ✅"

## Summary
| Category | Total Count | Blocking Issues |
| :--- | :--- | :--- |
| CVE / Vulnerabilities | ... | ... |
| Wrong RN Type (CVE) | ... | ... |
| Missing Release Notes | ... | ... |
| Wrong Status | ... | ... |
| Missing /hold on Open PRs | ... | ... |
| Private Issues Requiring Public Clones | ... | ... |

### Code-Freeze Blockers & Action Items
- Bulleted critical blockers requiring immediate resolution.
- General guidance: Resolve intent directly or contact assignees.
- Release Readiness Score: `<PERCENTAGE>%`
```

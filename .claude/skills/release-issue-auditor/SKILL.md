---
name: release-issue-auditor
description: >
  Audits JIRA issues for an upcoming release to ensure statuses, release notes, 
  and PRs meet code-freeze requirements. Automatically deduces z-stream versions, 
  discovers custom fields, checks PR labels via GitHub CLI, and outputs a triage report.
  Use when auditing release readiness for code freeze, or checking if issues meet release criteria.
argument-hint: '6.2.13'
---

# Audit Release Issues for Code-Freeze

## Overview

Audit a list of JIRA issues for an upcoming release to ensure they are ready for QE, have the correct release notes fields, and have appropriate `/hold` labels on open PRs.

## Workflow

### Step 1: Parse versions and construct JQL

Ask the user which version they want to audit if not provided (e.g., `6.2.13` or `6.6.z`).

**Version Expansion Rule:**
When the user provides a shorthand patch version (e.g., `6.2.13`), you MUST automatically:
1. Prepend the project name "Logging " (e.g., `"Logging 6.2.13"`).
2. Deduce and include the corresponding `.z` stream version (e.g., `"Logging 6.2.z"`).
3. If the user only provides `6.2.z`, format it as `"Logging 6.2.z"`.

Construct the following JQL query:
```text
project = "OpenShift Logging" AND type in (Bug, Task, Story, Vulnerability, Weakness) AND status not in (New, "To Do", Assigned, "In Progress") AND fixVersion in (<TARGET_VERSIONS>) ORDER BY key ASC
```

### Step 2: Jira Custom Fields

The following field IDs are stable across Red Hat Jira instances (redhat.atlassian.net):

- **Release Note Text:** `customfield_10783` — Stores the actual release note content
- **Release Note Type:** `customfield_10785` — Options: "Bug Fix", "Enhancement", "CVE - Common Vulnerabilities and Exposures", "Release Note Not Required"
- **Release Note Status:** `customfield_10807` — Workflow status of release notes
- **Sprint:** `customfield_10007` — Current sprint assignment
- **Security:** `security` — Standard field: null = public, has value = private/restricted

Do NOT attempt dynamic discovery. Use these field IDs directly in all API calls.

### Step 3: Fetch Issues & Extract Data

Execute the search using the MCP JIRA tool. Fetch the required fields.

**Required Fields:**
- `key` — Issue key (e.g., LOG-9940)
- `summary` — Issue summary
- `status` — Current status
- `issuetype` — Issue type (Bug, Task, Vulnerability, Weakness, etc.)
- `assignee` — Issue assignee
- `labels` — Labels (check for `no-rn` and CVE markers)
- `security` — Security level (check if private/restricted)
- `issuelinks` — Needed for GitHub PR extraction
- `customfield_10007` — Sprint
- `customfield_10783` — Release Note Text
- `customfield_10785` — Release Note Type
- `customfield_10807` — Release Note Status

**MCP Approach:**
```bash
mcp__atlassian__searchJiraIssuesUsingJql \
  --cloudId https://redhat.atlassian.net \
  --jql "$CONSTRUCTED_JQL" \
  --fields '["key","summary","status","issuetype","assignee","labels","security","issuelinks","customfield_10007","customfield_10783","customfield_10785","customfield_10807"]' \
  --maxResults 100
```

**CRITICAL:** Include `customfield_10783` and `customfield_10785` in the fields array - these are required for Release Note validation in Step 4.

### Step 4: Audit each issue

For each issue, apply the validation rubric:

**1. CVE/Vulnerability Issues (issuetype == "Vulnerability"):**
- **Release Note Type MUST be:** "CVE - Common Vulnerabilities and Exposures"
- **Release Note Text:** Not required (CVEs do not include detailed release notes)
- **Security Level:** May be set (expected for CVE tracking)
- **Action:** Flag if Release Note Type is anything other than CVE option

**2. Non-CVE Issues (Bug, Task, Weakness, Story, etc.):**
- **Release Note Requirement:** Must satisfy ONE of:
  - Has Release Note Text (customfield_10783 is not null) AND Release Note Type is set, OR
  - Has 'no-rn' label in labels, OR
  - Release Note Type == "Release Note Not Required"
- **Security Level:** Flag if issue has security restrictions (private issues cannot be disclosed in public release notes)
- **Action:** Flag issue for the "Issues Missing Release Notes" section if it fails these requirements

**3. Status Check:**
- Acceptable statuses: "Release Pending", "Review", "Modified", "Verified", "POST"
- Block if status is: "Code Review" (must move to Review or Release Pending before code-freeze)

**4. Private Issue Check:**
- If `security` field is not null AND `issuetype != "Vulnerability"`:
  - Issue is **private/restricted** and cannot be mentioned in public release notes
  - Must either have 'no-rn' label OR be linked to a public clone

**5. GitHub PR Check** (for issues in "Code Review" or "POST" status):
- Extract linked GitHub PRs from `issuelinks` (look for PR URLs in external links)
- For each PR, run: `gh pr view <PR_URL> --json labels -q '.labels[].name'`
- **Flag if:** PR does not have `/hold` label (required before code-freeze)

### Step 5: Generate and Save Audit Report

You MUST generate the full, comprehensive audit report containing all 6 sections. Do not ask for permission, and do NOT output a short summary instead of the full report.

**Bulk Action Links:**
For any section containing flagged issues (Sections 2, 4, 5, and 6), you MUST generate a clickable Jira link that opens all those specific issues at once.
Construct the URL like this: `https://redhat.atlassian.net/issues/?jql=key%20in%20(LOG-1,LOG-2,LOG-3)`

**File Output (MANDATORY):**
You MUST write the complete Markdown report to a file named `RELEASE_AUDIT_<VERSION>.md` (e.g., `RELEASE_AUDIT_6.5.3.md`) in the current workspace directory.
After saving the file, print a brief confirmation to the user that the file was created, along with the "Summary" section of the report.

## Audit Report Output Format

Use exactly this format for the file:

# Release Audit Report: Logging X.Y.Z / X.Y.z

## 1. CVE/Vulnerability Issues
**Count:** N
- List of all CVE/Vulnerability issues with assignees (Include Issue Keys)

## 2. CVEs with Wrong Release Note Type
**Count:** N (should be 0)
*[View Issues in Jira](https://redhat.atlassian.net/issues/?jql=key%20in%20(...))*
- List of CVEs with incorrect Release Note Type (Include Issue Keys)

## 3. Other Issues (Bug, Task, Weakness, etc.)
**Count:** N
- Table with: Issue Key, Type, Assignee, Status, RN Type

## 4. Issues Missing Release Notes
**Count:** N ❌ BLOCKING
*[View Issues in Jira](https://redhat.atlassian.net/issues/?jql=key%20in%20(...))*
- **Criteria:** Non-CVE with no RN Text AND no 'no-rn' label AND RN Type ≠ "Release Note Not Required"
- For each: Key, Type, Assignee, Status, Action Required

## 5. Private Issues with Security Level (Non-CVE)
**Count:** N (should be 0)
*[View Issues in Jira](https://redhat.atlassian.net/issues/?jql=key%20in%20(...))*
- Only lists non-CVE issues with security != null
- If count = 0, states "No private issues found" ✅

## 6. PRs Missing /hold Label
**Count:** N (should be 0) ❌ BLOCKING
*[View Issues in Jira](https://redhat.atlassian.net/issues/?jql=key%20in%20(...))*
- PR URL | Linked Jira Issue | Assignee
- If count = 0, states "All PRs have /hold label" ✅

## Summary
- Table with counts across all categories
- Code-Freeze Blockers (CRITICAL actions required)
- Sign-off with release readiness percentage

## Implementation Notes
- **MCP JIRA:** Configured in Claude Code (uses `mcp__atlassian__searchJiraIssuesUsingJql`).
- **GitHub CLI:** `gh` pre-authenticated for PR label checks.
- **Error Handling:** If MCP fails or misses required fields, report the error and stop. Treat missing security fields as public (null).

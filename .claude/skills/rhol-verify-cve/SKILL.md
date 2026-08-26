---
name: rhol-verify-cve
description: >
  Verify if a pull request or Jira issue satisfies CVE requirements by evaluating
  dependency changes (Go modules, base images, runtime versions). Determines if the
  fix requires a Go dependency upgrade, base image upgrade, or is already resolved.
argument-hint: "[PR-URL | LOG-XXXX]"
---

# Verify CVE Fixes

## Overview

Evaluate whether a pull request or Jira CVE issue properly addresses the vulnerability by:
1. Identifying the CVE requirement (dependency upgrade, runtime upgrade, or resolution status)
2. Analyzing all dependency changes in the PR
3. Cross-referencing with CVE databases (NVD, Red Hat Security)
4. Verifying the fix is sufficient and complete

## Usage

```
/rhol-verify-cve https://github.com/openshift/cluster-logging-operator/pull/1234
/rhol-verify-cve LOG-1234
```

## Input Recognition

- **GitHub PR URL:** Extract owner, repo, and PR number from URL
- **Jira issue key:** LOG-XXXX format
- Accept both as arguments

## Workflow

### Step 1: Fetch CVE Details

#### If Jira Issue (LOG-XXXX)
1. Load `/jira:jira` skill for Jira CLI reference
2. Fetch the issue:
   ```bash
   acli jira workitem view LOG-XXXX --json
   ```
3. Extract:
   - Summary (CVE ID if present)
   - Description (CVE details, affected components)
   - Linked issues (look for "relates to", "blocks" links to PRs)
   - Custom fields: severity, affected versions
   - PR links in issue or description

#### If GitHub PR URL
1. Fetch PR metadata:
   ```bash
   gh pr view <URL> --json title,body,files,commits,statusCheckRollup
   ```
2. Extract CVE reference from:
   - PR title
   - PR description/body
   - Commit messages
3. Search for linked Jira issues in PR body

### Step 2: Identify CVE Requirement

Query CVE databases to determine fix type:

**Go Dependency Upgrade:**
- CVE affects a Go module dependency
- Required upgrade version specified in NVD/GHSA advisory
- Affects: vendor/, go.mod

**Rust Dependency Upgrade:**
- CVE affects a Rust crate dependency
- Required upgrade version specified in NVD/GHSA advisory
- Affects: Cargo.toml, Cargo.lock

**Rust Runtime/MSRV Upgrade:**
- CVE in Rust compiler/runtime itself
- Requires minimum supported Rust version (MSRV) bump
- Affects: Cargo.toml (rust-version), .github/workflows, CI config

**Base Image Upgrade:**
- CVE in base OS image (e.g., Alpine, UBI, Fedora)
- Requires Dockerfile FROM image tag update
- Affects: Dockerfile, .containerignore, image SHAs

**Go Runtime Version Upgrade:**
- CVE in Go runtime itself (language vulnerability)
- Requires Go version bump in CI/CD config
- Affects: go.mod, Dockerfile, CI files (go-version)

**Already Resolved:**
- CVE already patched in current code
- No action required

### Step 2.5: Verify CVE Dependency Exists in Codebase

Before proceeding with CVE verification, confirm the affected module/package actually exists in the codebase:

**Extract affected module from CVE ID:**
```bash
# From NVD/GHSA search, identify which module the CVE affects
# Example: CVE-2026-29181 affects module X
# Cross-reference Jira issue description for CVE ID and affected module name
AFFECTED_MODULE=$(extract_from_cve_database "$CVE_ID")
```

**For Go dependencies:**
```bash
# Check if the CVE-affected module is in the current go.mod (before PR)
# and whether it was changed in the PR
if grep -q "^require.*$AFFECTED_MODULE" go.mod; then
  echo "✓ Module $AFFECTED_MODULE found in go.mod"
  # Proceed with version verification
else
  echo "✗ Module $AFFECTED_MODULE NOT in go.mod - CVE cannot be fixed in this repo"
  # Flag in final report as CANNOT-FIX
fi

# IMPORTANT: Also check if module appears in PR diff changes
# If CVE is mentioned in Jira but module is not in the PR diff, flag as orphaned
if ! git diff origin/main HEAD -- go.mod | grep -q "$AFFECTED_MODULE"; then
  echo "⚠ Module $AFFECTED_MODULE mentioned in CVE but NOT in PR changes - Orphaned CVE"
fi
```

**For base images:**
```bash
# Check if the CVE-affected image is referenced in any Dockerfile
AFFECTED_IMAGE=$(extract_from_cve_database "$CVE_ID")
if grep -r "^FROM.*$AFFECTED_IMAGE" Dockerfile*; then
  echo "✓ Image $AFFECTED_IMAGE found in Dockerfile"
else
  echo "✗ Image $AFFECTED_IMAGE NOT used - CVE cannot be fixed in this repo"
  # Flag in final report as CANNOT-FIX
fi
```

**Flag unresolvable CVEs:**
- If CVE is mentioned in Jira but the affected dependency/image is NOT in the codebase:
  - **Status:** ⚠ CANNOT-FIX (Dependency Not in Codebase)
  - **Note:** "CVE-XXXX affects [MODULE/IMAGE] which is not used by this codebase. No fix required."
- If CVE is mentioned in Jira issue description but the affected module does NOT appear in PR changes:
  - **Status:** ⚠ ORPHANED-CVE (Referenced but Not Fixed)
  - **Note:** "CVE-XXXX was referenced in issue but [MODULE] is not being upgraded. This CVE cannot be fixed by this PR."

### Step 2.6: Validate Claimed CVE Modules Against PR Diff AND Base Branch

Before proceeding, verify that modules mentioned in the PR title/description/body:
1. Actually appear in the PR diff (being changed)
2. Exist in the base branch (valid project dependency)

**VALID:** Module in base branch go.mod (direct OR indirect) AND changed in PR diff
**INVALID:** Module NOT in base branch go.mod OR NOT changed in PR diff

```bash
# Extract modules mentioned in PR title AND description/body
PR_TITLE=$(gh pr view <PR_URL> --json title -q '.title')
PR_BODY=$(gh pr view <PR_URL> --json body -q '.body')

# Search for module references in title
CLAIMED_IN_TITLE=$(echo "$PR_TITLE" | \
  grep -oP '(?:bump|upgrade|update)\s+([a-zA-Z0-9/_.-]+)(?:\s+to|->\s+)?v[0-9.]' | \
  grep -oP '[a-zA-Z0-9/_.-]+(?=(?:\s+to|->\s+)?v)' | sort -u)

# Search for module references in body
CLAIMED_IN_BODY=$(echo "$PR_BODY" | \
  grep -oP '(?:bump|upgrade|update|fix|address)\s+[`]?([a-zA-Z0-9/_.-]+)[`]?' | \
  grep -oP '[a-zA-Z0-9/_.-]+$' | sort -u)

PR_CLAIMED_MODULES=$(echo -e "$CLAIMED_IN_TITLE\n$CLAIMED_IN_BODY" | sort -u)

echo "Modules claimed in PR title/description/body:"
echo "$PR_CLAIMED_MODULES"

# Extract modules actually changed in go.mod diff
PR_DIFF_MODULES=$(git diff $FULL_REF HEAD -- go.mod | \
  grep -E '^\+.*require' | \
  grep -oP '\s+([a-zA-Z0-9/_.-]+)\s+v[0-9.]' | \
  sed 's/^\s*//; s/\s.*$//' | sort -u)

echo "Modules actually changed in go.mod diff:"
echo "$PR_DIFF_MODULES"

# For each claimed module, validate it
INVALID_MODULES=()
for MODULE in $PR_CLAIMED_MODULES; do
  # Check 1: Is it in the PR diff?
  if ! echo "$PR_DIFF_MODULES" | grep -q "^$MODULE$"; then
    echo "❌ INVALID: PR claims to fix $MODULE but module NOT in go.mod diff"
    INVALID_MODULES+=("$MODULE")
    continue
  fi
  
  # Check 2: Does it exist in base branch? (will be verified in Step 5.5d)
  # If not in base, will be flagged later as NOT_FOUND
  echo "✓ $MODULE: Found in PR diff, will validate against base branch later"
done

if [ ${#INVALID_MODULES[@]} -gt 0 ]; then
  echo ""
  echo "❌ CRITICAL: PR incorrectly references these modules (not in code changes):"
  for MOD in "${INVALID_MODULES[@]}"; do
    echo "   - $MOD (mentioned in PR title/body but NOT in go.mod changes)"
    echo "     → Linked Jira CVE issue should be removed from PR"
  done
fi
```

**Flag as critical issue:**
- If PR title/body claims to fix CVE for module X but module X doesn't appear in go.mod diff → **PR incorrectly linked to Jira CVE issue** (remove from PR or add the code change)
- If module appears in PR diff but NOT in base branch → **Also invalid (module doesn't exist in project)**

### Step 3: Analyze Changed Files

For each PR commit, extract files changed and categorize:

```bash
gh pr view <URL> --json commits | jq '.commits[].files'
```

**Dependency Change Detection:**

| File Pattern | Type | Action |
|---|---|---|
| `go.mod`, `go.sum` | Go deps | Parse and extract version changes |
| `Cargo.toml`, `Cargo.lock` | Rust deps | Parse and extract version changes |
| `Dockerfile` | Base image | Extract `FROM` directive changes |
| `.go-version` | Go version | Check version bump |
| `vendor/modules.txt` | Vendored deps (Go) | Extract changes |
| `.github/workflows/*` | CI config | Check `go-version:` and `rust-version:` values |
| `rust-toolchain.toml` | Rust version | Extract version and MSRV |

### Step 4: Extract Versions

#### Go Dependency Changes
```bash
# From PR diff, extract changes to go.mod
# Pattern: 'require module-name vX.Y.Z'
```

For each changed dependency:
- Extract old version
- Extract new version
- Record if version increased (indicates fix attempt)

#### Rust Dependency Changes
```bash
# From PR diff, extract changes to Cargo.toml or Cargo.lock
# Pattern in Cargo.toml: '[dependencies]' or '[dev-dependencies]'
# name = "X.Y.Z" or name = { version = "X.Y.Z" }'
```

For each changed crate:
- Extract old version
- Extract new version
- Record if version increased (indicates fix attempt)
- Check Cargo.lock for transitive dependency updates

#### Rust MSRV/Runtime Changes
```bash
# Check Cargo.toml 'rust-version' or rust-toolchain.toml
# Pattern: 'rust-version = "1.XX"'
```

For Rust runtime CVEs:
- Extract old MSRV
- Extract new MSRV
- Verify meets minimum requirement from advisory

#### Base Image Changes
```bash
# Extract FROM lines in Dockerfile diffs
# Pattern: 'FROM registry/image:tag'
```

Compare:
- Old image SHA or tag
- New image SHA or tag
- Verify tag date is newer (if tag is a date)

#### Go Runtime Changes
```bash
# Check .go-version or go.mod 'go' directive
# Pattern: 'go X.Y.Z'
```

### Step 5: Cross-Reference with CVE Data

For each CVE identified, search multiple databases and extract minimum patched versions:

#### 5a. NVD (nvd.nist.gov)
```
Search URL: https://nvd.nist.gov/vuln/search?query=<CVE-ID>
Extract:
  - Affected versions range (e.g., "golang.org/x/net < 0.38.0")
  - Fixed/patched version minimum (e.g., ">= 0.38.0")
  - CVSS severity score
  - Publication date
```

#### 5b. GHSA (GitHub Security Advisory Database)
```
Search URL: https://github.com/advisories?query=<CVE-ID>
Also: https://github.com/advisories/GHSA-XXXX-XXXX-XXXX
Extract:
  - Package name (must match module in go.mod)
  - Affected version range
  - Patched version(s)
  - Severity
  - Description
```

#### 5c. Go Security Database (pkg.go.dev)
```
Search URL: https://pkg.go.dev/vuln/<CVE-ID> or https://pkg.go.dev/vuln/GO-YYYY-NNNN
Extract:
  - Go-specific module CVE ID (GO-YYYY-NNNN format)
  - Affected versions
  - Minimum patched version
  - Go-specific impact analysis
```

#### 5d. Red Hat Security (access.redhat.com)
```
Search URL: https://access.redhat.com/security/cve/<CVE-ID>
Extract:
  - Red Hat severity (Critical, Important, Moderate, Low)
  - Impact statement
  - Affected Red Hat packages
  - Fixed versions in Red Hat repos
```

#### 5e. Vulnerability Tracking Services
```
- vulert.com/vuln-db: Quick CVE lookups with version info
- snyk.io: OSV database with Go module support
- cves.io: Aggregated CVE data
```

#### 5f. Extract and Compare Versions

For each CVE found:
```
1. Record:
   - CVE ID
   - Affected module/package
   - Affected version range (e.g., "< 0.38.0")
   - Minimum patched version (e.g., ">= 0.38.0")
   - Severity and CVSS score
   
2. Compare with PR changes:
   - Old version in go.mod: X.Y.Z
   - New version in go.mod: A.B.C
   - Required minimum: M.N.O
   
3. Verify:
   - IF new_version >= required_minimum: ✓ PASS
   - IF new_version < required_minimum: ✗ FAIL
   
4. Check all affected modules:
   - If CVE affects multiple modules (e.g., golang.org/x/net 
     and golang.org/x/crypto), verify ALL are bumped
```

#### 5g. Automated Cross-Reference Workflow

**For each module in go.mod that was bumped:**

1. **Extract module name and versions:**
   ```
   MODULE=golang.org/x/net
   OLD_VERSION=v0.55.0
   NEW_VERSION=v0.58.0
   ```

2. **Search all CVE databases in parallel:**
   ```bash
   # 1. OpenCVE (fastest, no auth)
   CVES=$(curl -s "https://api.opencve.io/cve?search=$MODULE&limit=100" \
     | jq -r '.[].id' | sort | uniq)
   
   # 2. Go Security Database
   GO_CVES=$(curl -s "https://raw.githubusercontent.com/golang/vulndb/main/index.json" \
     | jq -r ".[] | select(.modules[].mod == \"$MODULE\") | .id" | sort | uniq)
   
   # 3. GHSA via GitHub advisories
   GHSA=$(gh api --method GET repos/github/advisory-database/contents/advisories/go \
     --jq '.[] | select(.name | contains("'$MODULE'")) | .name')
   
   # Combine all CVEs found
   ALL_CVES=$(echo "$CVES $GO_CVES $GHSA" | tr ' ' '\n' | sort | uniq)
   ```

3. **For each CVE found, extract minimum patched version:**
   ```bash
   for CVE in $ALL_CVES; do
     # Get CVE details
     CVE_DATA=$(curl -s "https://api.opencve.io/cve/$CVE" | jq '.')
     
     # Extract affected versions
     AFFECTED=$(echo "$CVE_DATA" | jq -r '.affected[0].version' | head -1)
     
     # Find minimum fixed version by parsing advisory
     # This requires parsing the description or affected version ranges
     # Pattern: "versions before X.Y.Z", "fixed in X.Y.Z", ">= X.Y.Z"
     MIN_FIXED=$(echo "$CVE_DATA" | jq -r '.description' \
       | grep -oP '(?:before|fixed in|version|>= |v)\K[0-9]+\.[0-9]+\.[0-9]+' \
       | head -1)
     
     # Compare versions using semantic versioning
     if version_gte "$NEW_VERSION" "$MIN_FIXED"; then
       echo "✓ $CVE: MIN=$MIN_FIXED, PR=$NEW_VERSION -> PASS"
     else
       echo "✗ $CVE: MIN=$MIN_FIXED, PR=$NEW_VERSION -> FAIL"
     fi
   done
   ```

4. **Version comparison helper:**
   ```bash
   # Semantic version comparison function
   function version_gte() {
     printf '%s\n%s' "$2" "$1" | sort -V -r | head -n1 | grep -q "^$1"
   }
   
   # Usage: if version_gte "v0.58.0" "v0.38.0"; then echo "PASS"; fi
   ```

5. **Generate cross-reference matrix:**
   ```
   Build a table:
   CVE ID | Severity | Module | Min Fixed | PR Version | Status
   ```

6. **Output final determination:**
   - **If ALL CVEs are satisfied:** ✓ VERIFIED
   - **If ANY CVE is not satisfied:** ✗ UNRESOLVED
   - **If CVEs found but versions unclear:** ⚠ NEEDS-CLARIFICATION
   - **If no CVEs found for module:** ? NO-CVE-FOUND

Determine:
- **Required minimum version** (if upgrade)
- **Affected versions range**
- **Status:** Fixed, Disputed, Underway, Unresolved
- **Severity:** Critical, High, Medium, Low

### Step 5.5: Validate Jira Issue Links Against Codebase Dependencies

**MANDATORY CHECK:** For each linked Jira issue (LOG-XXXX), verify the CVE it references has an affected dependency that exists in the codebase:

**Step 5.5a: Extract CVE ID from each linked Jira issue**
```bash
# For each linked Jira issue, extract CVE ID
for JIRA_ISSUE in $LINKED_ISSUES; do
  CVE_ID=$(acli jira workitem view "$JIRA_ISSUE" --json | jq -r '.summary' | grep -oP 'CVE-\d+-\d+|GHSA-[A-Za-z0-9]+-[A-Za-z0-9]+-[A-Za-z0-9]+' | head -1)
  echo "$JIRA_ISSUE: $CVE_ID"
done
```

**Step 5.5b: For each CVE, query affected module from database**
```bash
# Query NVD or GHSA to find which module/package this CVE affects
for CVE_ID in $EXTRACTED_CVES; do
  # Search NVD API
  AFFECTED_MODULE=$(curl -s "https://services.nvd.nist.gov/rest/json/cves/1.0?keyword=$CVE_ID" \
    | jq -r '.result.CVE_Items[0].cve.affects.vendor[0].product[0].product_name // empty')
  
  # Or search GHSA
  if [ -z "$AFFECTED_MODULE" ]; then
    AFFECTED_MODULE=$(gh api repos/github/advisory-database/contents/advisories \
      -f query="$CVE_ID" --jq '.[0].path' | xargs -I {} basename {})
  fi
  
  echo "$CVE_ID affects: $AFFECTED_MODULE"
done
```

**Step 5.5c: Detect the PR's base branch and ensure upstream remote exists**

First, determine which branch the PR targets and set up the upstream remote:

```bash
# Extract base branch from PR metadata
BASE_BRANCH=$(gh pr view <PR_URL> --json baseRefName -q '.baseRefName')
# Result might be: main, release-5.x, release-6.x, etc.

echo "PR targets base branch: $BASE_BRANCH"

# Extract repo owner and name from PR URL (e.g., openshift/cluster-logging-operator)
# PR_URL format: https://github.com/OWNER/REPO/pull/NUMBER
REPO_OWNER=$(echo "$PR_URL" | sed -E 's|.*/([^/]+)/([^/]+)/pull.*|\1|')
REPO_NAME=$(echo "$PR_URL" | sed -E 's|.*/([^/]+)/([^/]+)/pull.*|\2|')

echo "PR repository: $REPO_OWNER/$REPO_NAME"

# Use 'upstream' as the remote name for the official repo
REMOTE_NAME="upstream"

# Check if upstream remote already exists
if ! git remote | grep -q "^$REMOTE_NAME$"; then
  echo "⚠️  Remote '$REMOTE_NAME' not found. Adding it..."
  # Add upstream remote pointing to the official repo
  git remote add $REMOTE_NAME "https://github.com/$REPO_OWNER/$REPO_NAME.git" 2>/dev/null || {
    # If it already exists (race condition), just continue
    true
  }
  echo "✓ Upstream remote added: https://github.com/$REPO_OWNER/$REPO_NAME.git"
fi
```

**Step 5.5d: Attempt to fetch and verify modules on the base branch**

CRITICAL: Check the module against the PR's base branch (not always main). A module appearing in the PR diff does NOT mean it was in the codebase before. Also distinguish between DIRECT dependencies and TRANSITIVE dependencies — a CVE issue should only apply to direct dependencies.

```bash
# Construct the full ref using the upstream remote
FULL_REF="$REMOTE_NAME/$BASE_BRANCH"

# Always fetch the base branch from upstream to ensure latest
echo "Fetching $BASE_BRANCH from $REMOTE_NAME..."
git fetch $REMOTE_NAME $BASE_BRANCH 2>/dev/null || {
  echo "❌ CANNOT ACCESS BASE BRANCH: $FULL_REF could not be fetched"
  echo "   The skill cannot verify modules without access to the base branch."
  echo "   USER ACTION REQUIRED: See Section 5.5e for manual verification steps."
  BASE_BRANCH_AVAILABLE="NO"
}

# For each CVE and its affected module, verify it existed BEFORE the PR
# CRITICAL DISTINCTION: Only DIRECT dependencies can have CVE issues
# - DIRECT: explicitly listed in go.mod require (no // indirect comment)
# - INDIRECT: listed in go.mod with // indirect comment (managed by parent dep)
# - NOT FOUND: not in go.mod at all (PR incorrectly references this CVE)
for CVE_ID in $EXTRACTED_CVES; do
  AFFECTED_MODULE=$(get_affected_module "$CVE_ID")
  
  if [ "$BASE_BRANCH_AVAILABLE" = "NO" ]; then
    echo "⚠️  SKIPPING: Cannot verify $AFFECTED_MODULE without access to $BASE_BRANCH"
    UNVERIFIED_CVES+=("$CVE_ID → $AFFECTED_MODULE on $BASE_BRANCH")
    continue
  fi
  
  # CHECK AGAINST THE BASE BRANCH ($FULL_REF)
  # For Go modules: Check go.mod (not go.sum — go.sum includes all transitive)
  # go.mod distinguishes DIRECT (no comment) vs INDIRECT (// indirect comment)
  
  DEPENDENCY_STATUS="NOT_FOUND"
  
  # Extract the require line for this module from go.mod
  REQUIRE_LINE=$(git show $FULL_REF:go.mod 2>/dev/null | grep "^require.*$AFFECTED_MODULE")
  
  if [ -n "$REQUIRE_LINE" ]; then
    # Check if it's marked as indirect
    if echo "$REQUIRE_LINE" | grep -q "// indirect"; then
      echo "⚠️  $CVE_ID: $AFFECTED_MODULE found in go.mod but marked INDIRECT (// indirect comment)"
      DEPENDENCY_STATUS="INDIRECT"
      # INDIRECT dependencies are managed by their parent; CVE issues should track direct deps only
      echo "   → CVE issue $JIRA_ISSUE should track the DIRECT parent dependency, not this indirect dep"
    else
      echo "✓ $CVE_ID: $AFFECTED_MODULE is a DIRECT dependency in go.mod (on $FULL_REF)"
      DEPENDENCY_STATUS="DIRECT"
      RESOLVABLE="YES"
    fi
  # Check Cargo.toml for Rust crates (DIRECT only)
  elif git show $FULL_REF:Cargo.toml 2>/dev/null | grep -q "^\[$AFFECTED_MODULE\]\|name\s*=\s*\"$AFFECTED_MODULE\""; then
    echo "✓ $CVE_ID: $AFFECTED_MODULE is a DIRECT dependency in Cargo.toml (on $FULL_REF)"
    DEPENDENCY_STATUS="DIRECT"
    RESOLVABLE="YES"
  # Check Dockerfile for base images (DIRECT only)
  elif git show $FULL_REF:Dockerfile 2>/dev/null | grep -q "^FROM.*$AFFECTED_MODULE"; then
    echo "✓ $CVE_ID: $AFFECTED_MODULE found in Dockerfile (on $FULL_REF)"
    DEPENDENCY_STATUS="DIRECT"
    RESOLVABLE="YES"
  fi
  
  # Flag orphaned CVEs based on dependency status
  if [ "$DEPENDENCY_STATUS" = "INDIRECT" ]; then
    echo "✗ CVE ISSUE MISMATCH: $JIRA_ISSUE → $CVE_ID references INDIRECT dependency $AFFECTED_MODULE"
    ORPHANED_JIRA_ISSUES+=("$JIRA_ISSUE → $CVE_ID ($AFFECTED_MODULE is INDIRECT, not DIRECT - issue should track parent dep)")
    RESOLVABLE="NO"
  elif [ "$DEPENDENCY_STATUS" = "NOT_FOUND" ]; then
    echo "✗ NOT IN CODEBASE: $JIRA_ISSUE → $CVE_ID references $AFFECTED_MODULE which does NOT exist in $FULL_REF"
    ORPHANED_JIRA_ISSUES+=("$JIRA_ISSUE → $CVE_ID ($AFFECTED_MODULE NOT IN CODEBASE - PR incorrectly references this issue)")
    RESOLVABLE="NO"
  fi
done
```

**Step 5.5e: If base branch is unavailable, provide manual verification instructions**

If the skill cannot access `$FULL_REF`, report this explicitly and provide the user with manual verification steps:

```
⚠️  BASE BRANCH VERIFICATION UNAVAILABLE

The PR targets: release-6.5
Remote: upstream (openshift/cluster-logging-operator)
The skill cannot automatically verify if CVE modules exist on upstream/release-6.5.

MANUAL VERIFICATION STEPS (run these):

1. Fetch the base branch:
   git fetch upstream release-6.5

2. Check if affected modules exist on the base branch:
   git show upstream/release-6.5:go.mod | grep -E "golang.org/x/net|go.opentelemetry.io/otel|github.com/moby/spdystream"

3. If modules ARE found:
   → No orphaned CVEs, PR is safe to merge

4. If modules are NOT found:
   → LOG-9932, LOG-9927, LOG-9897 may be orphaned CVEs
   → Escalate to security team for clarification

5. Cross-check CVE IDs in Jira issues:
   acli jira workitem view LOG-9927,LOG-9932,LOG-9897 --json | jq '.[] | .summary'
```

**IMPORTANT:** If a module appears in the PR diff but NOT in the base branch, it is a **transitive/indirect dependency** that may have been pulled in by another upgrade. In this case:
- If the module is not explicitly managed by this project, the CVE issue is **orphaned**
- Flag it as: `⚠ ORPHANED: $JIRA_ISSUE references $CVE_ID affecting $AFFECTED_MODULE, which is not a direct dependency on $BASE_BRANCH`

**Step 5.5e: Flag orphaned CVE issues in final report**
- If a Jira issue is linked to the PR but the CVE it references has NO affected dependency in the base branch:
  - **Add to "Unresolvable CVEs" section in final report**
  - **Mark as:** `⚠ ORPHANED-CVE-ISSUE: $JIRA_ISSUE → $CVE_ID (module: $AFFECTED_MODULE not in $BASE_BRANCH)`
  - **Example:** `⚠ ORPHANED: LOG-9932 → CVE-2026-29181 (module X not found in release-5.x)`
  - This indicates the issue was incorrectly linked to the PR since it cannot be fixed in this release branch

### Step 6: Verify Coverage

Check if PR changes cover ALL identified requirements:

**For Go dependency CVE:**
- ✓ go.mod version increased to required minimum
- ✓ go.sum reflects change
- ✓ vendor/ directory updated (if vendored)
- ✓ No transitive dependencies broken

**For Rust dependency CVE:**
- ✓ Cargo.toml version increased to required minimum
- ✓ Cargo.lock reflects change
- ✓ No transitive dependencies broken
- ✓ MSRV compatibility maintained

**For Rust MSRV/Runtime CVE:**
- ✓ Cargo.toml rust-version updated to required minimum
- ✓ rust-toolchain.toml updated (if present)
- ✓ CI workflows updated to use new MSRV
- ✓ No breaking changes to supported Rust versions

**For base image CVE:**
- ✓ Dockerfile `FROM` updated to patched image
- ✓ Image SHA/tag reflects patch date
- ✓ All Dockerfiles updated (if multiple)
- ✓ Build caches invalidated

**For Go runtime CVE:**
- ✓ Go version in go.mod `go` directive updated
- ✓ CI workflows use new version (.go-version)
- ✓ No backwards compatibility issues

### Step 7: Incomplete/Missing Checks

Flag if:
- CVE requires dependency upgrade but PR only updates one of multiple dependencies (Go or Rust)
- Cargo.lock updated but Cargo.toml version constraint not relaxed (or vice versa)
- Base image updated but old image still referenced elsewhere
- Go version updated in one file but not others
- Rust MSRV updated in Cargo.toml but not in rust-toolchain.toml or CI config
- No matching Jira issue for PR (or vice versa)
- Commit messages don't reference CVE ID
- Tests added/updated for the vulnerability

### Step 7b: Cross-Reference Verification Report

After cross-referencing all CVEs, generate a detailed verification table:

```
CROSS-REFERENCE VERIFICATION TABLE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Module: golang.org/x/net
Current Version (old):    v0.55.0
PR New Version:           v0.58.0

CVE ID      | Component      | Severity | Min Fixed | PR Version | Status
────────────┼────────────────┼──────────┼───────────┼────────────┼────────
CVE-2025-22872 | x/net/html    | MEDIUM   | v0.38.0  | v0.58.0    | ✓ PASS
CVE-2024-45338 | x/net/html    | HIGH     | v0.33.0  | v0.58.0    | ✓ PASS
GHSA-vvgc-356p | x/net/html    | MEDIUM   | v0.38.0  | v0.58.0    | ✓ PASS

Sources Checked:
  [✓] NVD (nvd.nist.gov)
  [✓] GHSA (github.com/advisories)
  [✓] Go Security DB (pkg.go.dev/vuln)
  [✓] Red Hat Security (access.redhat.com)

Verdict: ✓ VERSION MEETS ALL REQUIREMENTS

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

For each module with CVE findings:
- List all found CVEs affecting the module
- Show minimum patched version from each source
- Verify PR version meets ALL minimum requirements
- Flag any discrepancies (e.g., different min versions across sources)
- Mark as PASS, FAIL, or NEEDS-CLARIFICATION

### Step 8: Report Findings

Structure report as:

```
CVE Verification Report
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

CVE ID: CVE-XXXX-XXXXX (or GHSA-XXXX-XXXX-XXXX)
Issue: [LOG-1234](https://redhat.atlassian.net/browse/LOG-1234)
PR: [#1234](https://github.com/owner/repo/pull/1234)
Severity: [CRITICAL|HIGH|MEDIUM|LOW]
Status: ✓ VERIFIED | ⚠ PARTIAL | ✗ UNRESOLVED | ⚠ CANNOT-FIX | ? UNCLEAR

Requirement Type: Go Dependency | Rust Dependency | Base Image | Go Runtime | Rust MSRV | N/A

Dependency Check:
  ✓ All affected modules/images found in codebase
  ✗ Affected module/image NOT in codebase (CVE cannot be fixed)

Step 2.6 Validation Results (Claimed vs Actual):
  ✓ golang.org/x/net: Claimed in PR title ✓, Found in go.mod diff ✓
  ✗ go.opentelemetry.io/otel/sdk: Claimed in PR title ✓, NOT in go.mod diff ✗, NOT in go.sum ✗ — MODULE DOES NOT EXIST
  ✓ github.com/moby/spdystream: Claimed in PR title ✓, Found in go.mod diff ✓

INVALID JIRA REFERENCES:
  ✗ LOG-9932 → go.opentelemetry.io/otel/sdk: 
     - Claimed in PR title/description
     - Module does NOT exist in go.mod or go.sum
     - Module does NOT exist in any file of the codebase
     - ACTION REQUIRED: Remove LOG-9932 from PR — this Jira issue should not be linked
     - Reason: go.opentelemetry.io/otel/sdk is not a dependency of cluster-logging-operator

Valid Jira References:
  ✓ LOG-9927 → golang.org/x/net: DIRECT dependency, properly fixed
  ✓ LOG-9897 → github.com/moby/spdystream: INDIRECT dependency, valid to track with parent

Required Action:
  - Upgrade [module/crate] from X.Y.Z to minimum Z.Y.X+
  - OR: Upgrade Rust MSRV from 1.XX to 1.YY+
  - OR: N/A - dependency not in codebase

Changes Found:
  ✓ go.mod: [old] → [new]
  ✓ Cargo.toml: [old] → [new]
  ✓ Cargo.lock: transitive deps updated
  ✓ Dockerfile: [old image] → [new image]
  ✓ .go-version: [old] → [new]
  ✓ rust-toolchain.toml: [old] → [new]
  ⚠ vendor/ not updated (if vendored)
  ✗ Missing: additional base images or Cargo updates

Verification:
  ✓ Affected dependency exists in codebase
  ✗ Affected dependency does NOT exist in codebase
  ✓ Version meets minimum requirement
  ✗ Not all affected files updated
  ✓ No breaking changes detected

Cross-Reference Summary:
  - CVEs identified: [list]
  - CVEs resolvable in codebase: [list]
  - CVEs not resolvable (dependency absent): [list]
  - Orphaned Jira issues (linked but CVE unfixable): [list]
  - Sources checked: NVD, GHSA, Go Security DB, Red Hat Security
  - All minimum versions satisfied: [YES|NO|PARTIAL|N/A]
  
Verification Details:
  [For each CVE found]:
  ├─ CVE ID: CVE-XXXX-XXXXX or GHSA-XXXX-XXXX-XXXX
  ├─ Affected Module/Image: [name]
  ├─ Found in Codebase: [YES|NO]
  ├─ Min Fixed Version (NVD): vX.Y.Z (if in codebase)
  ├─ Min Fixed Version (GHSA): vX.Y.Z (if in codebase)
  ├─ Min Fixed Version (Go DB): vX.Y.Z (if in codebase)
  ├─ PR New Version: vA.B.C (if in codebase)
  ├─ Severity: CRITICAL|HIGH|MEDIUM|LOW
  └─ Status: ✓ SATISFIED | ✗ NOT SATISFIED | ⚠ CANNOT-FIX

Recommendation:
  [PASS|REQUEST-CHANGES|NEEDS-CLARIFICATION|CANNOT-FIX-NOT-IN-CODEBASE]

Notes:
  - Any ambiguities, partial coverage, or missing info
  - Cross-references to other Jira tickets or advisories
  - Which CVEs are matched to which Jira issues (LOG-XXXX)
  - For CVEs referenced in Jira but not in codebase: specify the module/image name and confirm it is not used
  - ORPHANED CVE ISSUES: List any Jira issues linked to the PR that reference CVEs the codebase cannot fix (e.g., LOG-9932 → CVE-2026-29181 unfixable because module not in codebase)

CVE Database References:
  - NVD: https://nvd.nist.gov/vuln/search?query=<CVE-ID>
  - GHSA: https://github.com/advisories?query=<CVE-ID>
  - Go Security DB: https://pkg.go.dev/vuln/<CVE-ID>
  - Red Hat Security: https://access.redhat.com/security/cve/<CVE-ID>
  - OSV Database: https://api.osv.dev/v1/query (POST request with package details)
```

## Cross-Reference Query Examples

### NVD Search
```bash
# Search for CVE by module name
curl -s "https://nvd.nist.gov/vuln/search?query=golang.org/x/net" \
  | grep -o "CVE-[0-9]\+-[0-9]\+" | sort | uniq

# Or use OpenCVE API (no auth required)
curl -s "https://api.opencve.io/cve?search=golang.org/x/net&limit=100" | jq '.[]'
```

### GHSA Search
```bash
# Search GitHub advisories for a module
gh api --method GET repos/github/advisory-database/search/code \
  -f query="golang.org/x/net" --jq '.items[] | .name'

# Or browse at:
# https://github.com/advisories?query=golang.org/x/net
```

### Go Security Database
```bash
# Query Go vulnerability database
curl -s "https://pkg.go.dev/vuln/<CVE-ID or GO-YYYY-NNNN>"

# Search Go vuln database for module
curl -s "https://raw.githubusercontent.com/golang/vulndb/main/index.json" \
  | jq '.[] | select(.modules[].mod == "golang.org/x/net")'
```

### Red Hat Security
```bash
# Red Hat CVE search (requires browser or authenticated API)
# https://access.redhat.com/security/cve/<CVE-ID>

# Or check via Errata Tool
curl -s "https://errata.engineering.redhat.com/api/v1/cves/<CVE-ID>.json"
```

### Snyk/OSV
```bash
# OSV (Open Source Vulnerabilities) - go-specific
curl -s "https://api.osv.dev/v1/query" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"package": {"ecosystem": "Go", "name": "golang.org/x/net"}}'
```

## Dependencies

- **GitHub CLI:** `gh` (for PR data, advisory search)
- **Jira CLI:** `acli` (for issue data)
- **Cargo CLI:** `cargo` (for parsing Cargo.toml/Cargo.lock if needed)
- **curl/jq:** For automated API queries against NVD, GHSA, Go Security DB
- **Web access:** 
  - nvd.nist.gov (NVD CVE database)
  - github.com/advisories (GHSA)
  - pkg.go.dev/vuln (Go Security Database)
  - access.redhat.com/security (Red Hat Security)
  - vulert.com/vuln-db (Vulnerability tracking)
  - security.snyk.io (Snyk OSV database)
  - api.osv.dev (Open Source Vulnerabilities)
- **Environment:** `$JIRA_USER`, `$JIRA_TOKEN`, GitHub authentication

## Error Handling

**PR not found:**
```
gh pr view <URL> returns error
→ Verify URL format and repo exists
```

**Jira issue not found:**
```
acli returns error
→ Check issue key exists in LOG project
```

**CVE ID not found:**
```
If CVE cannot be extracted or found in databases
→ Request user confirm CVE ID from issue description
→ Provide manual verification form
```

**Inconclusive results:**
```
If fix appears incomplete or unclear
→ List specific gaps
→ Suggest additional verification steps
```

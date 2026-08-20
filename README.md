# Red Hat OpenShift Logging Workspace

Cross-repo workspace for Red Hat OpenShift Logging — shared specs, routing, and AI conventions.

## Repositories

| Repo                                                                                                           | Purpose                                                       |
|----------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------|
| [vector](https://github.com/viaq/vector)                                                                       | Vector collector                                              |
| [cluster-logging-operator](https://github.com/openshift/cluster-logging-operator)                              | Cluster logging operator that deploys vector, Viaq data model |
| [data-model-docs](https://github.com/rhobs/observability-data-model/blob/main/cluster-logging.md)              | Data model docs                                               |
| [loki](https://github.com/grafana/loki)                                                                        | Loki backend with Kubernetes operator                         |
| [redhat-openshift-logging-docs](https://github.com/openshift/openshift-docs/tree/standalone-logging-docs-main) | Documentation for the Red Hat OpenShift Logging               |
| [eventrouter](https://github.com/openshift/eventrouter)                                                        | Kubernetes event log exporter                                 |
| [log-file-metric-exporter](https://github.com/viaq/log-file-metric-exporter)                                   | Prometheus exporter for pod log file byte volume; deployed by CLO as a DaemonSet |
| [logging-ui-plugin](https://github.com/openshift/logging-view-plugin)                                          | Logging OpenShift UI plugin                                   |

## Setup

Clone all repos into this directory:

```bash
make clone-repos
```

Pull latest changes in all repos:

```bash
make pull-repos
```

Remove all cloned repos to start fresh (re-clone with `make clone-repos`):

```bash
make remove-repos
```

## Specs

All specifications live in `.ai/spec/`. Start with [`.ai/spec/README.md`](.ai/spec/README.md) for the product overview and reading guide. Use [`.ai/spec/how/repo-map.md`](.ai/spec/how/repo-map.md) to find which repo and spec file to update for a given concern.

1. Create spec: a new spec files should be created with `/superpowers:brainstorming` [skill](https://github.com/obra/superpowers/tree/main).

   ```
   > /superpowers:brainstorming create or update specs for https://redhat.atlassian.net/browse/LOG-123.
   ```

   As an input use product requirements or design ideas. The output should be a set of spec files in `.ai/spec/`.
1. Create Jira tickets: in the same session run `/make-jira-from-spec` skill to create Jira tickets from the spec files.
1. Implementation: use `/superpowers:brainstorming` skill with the Jira ticket as an input. After the implementation is done ask agent to update the spec files based on the implementation.

### Create initial spec files

The `/spec-first:init` [skill](https://github.com/joshuawilson/spec-first) was used to create initial set of spec files. To install the `spec-first` plugin, run:

```bash
/plugin marketplace add joshuawilson/spec-first
/plugin install spec-first@spec-first-marketplace
```

Example prompt:
> /spec-first:init create the specs. Document which features are supported and which not. The supported features are the ones that are documented in the docs. These features are either generally available (GA) or tech-preview (TP). If a feature is in the source code, but missing in docs, it is
not supported.

## Verify Bug Fix

The `/verify-bug-fix` skill verifies that a JIRA bug fix resolves the reported issue. It fetches JIRA details, finds linked PRs, runs verification on a connected OpenShift cluster, and generates a JIRA-ready verification summary.

### Quick Start

```bash
/verify-bug-fix LOG-8727
```

### What It Does

1. **Fetches JIRA Issue** — retrieves summary, status, description, steps to reproduce, and fix version
2. **Finds Linked PRs** — scans JIRA remote links and comments for GitHub PR/commit URLs, fetches PR details via `gh`
3. **Derives Test Config** — determines the CLF/LokiStack spec from the JIRA steps to reproduce, PR test files, or component-based defaults (confirms with user before applying)
4. **Verifies on Cluster** — applies test config, checks operator versions, pod health, and runs fix-specific test scenarios
5. **Human Review** — presents all raw evidence without interpreting pass/fail
6. **Generates Summary** — after user confirmation, produces a structured verification summary for JIRA

### Prerequisites

Set JIRA credentials in `~/.claude/settings.json`:

```json
{
  "env": {
    "JIRA_TOKEN": "your-token-here",
    "JIRA_EMAIL": "your-email@redhat.com",
    "JIRA_URL": "https://redhat.atlassian.net"
  }
}
```

Additional tools:
- `gh` CLI — authenticated for GitHub access
- `oc` CLI — authenticated to an OpenShift cluster (optional; the skill still provides JIRA + PR info without a cluster)

### Graceful Degradation

- **No cluster connection**: stops after presenting JIRA issue and PR details
- **No PRs found**: asks the user to provide a PR link manually
- **GitHub API errors**: falls back to `gh pr view` or asks for PR details directly

## Conventions

- **Jira**: Project key `LOG` on `redhat.atlassian.net`
- **Git workflow**: Fork-based — push to your fork, PR against `origin/main`, squash before pushing
- **Per-repo guides**: Each repo has an `AGENTS.md` with repo-specific conventions

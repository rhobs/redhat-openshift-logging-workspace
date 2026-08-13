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
| [log-file-metric-exporter](https://github.com/viaq/log-file-metric-exporter)                                  | Log file metric exporter                                      |
| [logging-ui-plugin](https://github.com/openshift/logging-view-plugin)                                          | Logging OpenShift UI plugin                                   |

## Setup

Clone all repos into this directory:

```bash
git clone git@github.com:viaq/vector.git
git clone git@github.com:openshift/cluster-logging-operator.git
git clone git@github.com:openshift/eventrouter.git
git clone git@github.com:grafana/loki.git
git clone git@github.com:viaq/log-file-metric-exporter.git
git clone git@github.com:openshift/logging-view-plugin.git
git clone --single-branch --branch standalone-logging-docs-main git@github.com:openshift/openshift-docs.git
```

Pull all repos:

```bash
for d in vector cluster-logging-operator eventrouter loki log-file-metric-exporter logging-view-plugin openshift-docs; do
  [ -d "$d/.git" ] && echo "=== $d ===" && git -C "$d" pull --ff-only
done
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

## Conventions

- **Jira**: Project key `LOG` on `redhat.atlassian.net`
- **Git workflow**: Fork-based — push to your fork, PR against `origin/main`, squash before pushing
- **Per-repo guides**: Each repo has an `AGENTS.md` with repo-specific conventions

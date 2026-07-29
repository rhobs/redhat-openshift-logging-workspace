# Project Structure

Red Hat OpenShift Logging is a multi-repo workspace. Each repository is an independent git checkout within the workspace directory. The workspace repo itself contains only agent instructions, specs, and coordination files.

## Module Map

| Directory | Repository | Language | Responsibility |
|---|---|---|---|
| `cluster-logging-operator/` | `openshift/cluster-logging-operator` | Go | ClusterLogForwarder controller, Vector config generation, collector deployment |
| `loki/` | `grafana/loki` | Go | Upstream Loki + Loki Operator (LokiStack, AlertingRule, RecordingRule, RulerConfig) |
| `vector/` | `vectordotdev/vector` | Rust | Upstream Vector collector (sources, transforms, sinks) |
| `openshift-docs/` | `openshift/openshift-docs` (branch: `standalone-logging-docs-main`) | AsciiDoc | Product documentation — authoritative for supported features |
| `logging-view-plugin/` | `openshift/logging-view-plugin` | TypeScript + Go | OpenShift Console logging plugin (UI) |
| `.ai/spec/` | (workspace) | Markdown | Product specifications |
| `AGENTS.md` | (workspace) | Markdown | Cross-repo agent conventions |

## Key Entry Points

| Repo | Entry Point | Purpose |
|---|---|---|
| cluster-logging-operator | `cmd/main.go` | Operator binary, controller registration |
| cluster-logging-operator | `api/observability/v1/` | ClusterLogForwarder CRD types |
| cluster-logging-operator | `internal/controller/` | Reconciliation controllers |
| cluster-logging-operator | `internal/generator/vector/` | Vector configuration generation |
| loki | `operator/cmd/` | Loki Operator binary |
| loki | `operator/api/loki/v1/` | LokiStack, AlertingRule, RecordingRule, RulerConfig CRD types |
| loki | `operator/internal/` | Operator controllers and manifest generation |
| logging-view-plugin | `cmd/` | Go backend entry point |
| logging-view-plugin | `web/src/` | React frontend source |
| logging-view-plugin | `web/src/components/` | UI components (logs table, toolbar, histogram, filters) |
| openshift-docs | `modules/` | AsciiDoc content modules |
| openshift-docs | `assemblies/` | Assembly files composing modules into pages |

## Naming Conventions

- **CRD type files**: `<kind>_types.go` (e.g., `clusterlogforwarder_types.go`)
- **Controller files**: `<kind>_controller.go`
- **Output generators**: one package per output type under `internal/generator/vector/output/<type>/`
- **Test files**: `*_test.go` (Go), `*.test.ts` / `*.cy.ts` (TypeScript)
- **Doc modules**: `modules/<topic>-<subtopic>.adoc` (AsciiDoc)

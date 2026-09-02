# Vector Checkpoint Isolation - Per-Source Data Directories

**Status:** Implementation specification for LOG-9871 fix  
**Component:** cluster-logging-operator (Vector configuration generation)  
**Versions:** Affects 6.4, 6.6 (Vector 0.54); Fix for 6.7+  
**Related Issues:** LOG-9871, LOG-9442, LOG-9443

## Problem Statement

### Issue Description

Vector stops reading/sending logs for ALL outputs when one output (Loki) experiences backpressure from rate limiting (429 errors).

**Observable Symptoms:**
1. SpringBoot application restart generates log spike
2. Loki returns HTTP 429 (Too Many Requests) due to rate/stream limits
3. Logs from the affected namespace **stop going to Splunk** (unrelated output)
4. **ALL application logs stop going to Loki**
5. Vector collector requires pod restart to recover

**Impact:**
- Critical logs lost during incidents
- Separate outputs (Splunk, Loki) not isolated from each other's failures
- Violates expectation that output failures should be independent

### Affected Configurations

Occurs when:
- Multiple `kubernetes_logs` sources read overlapping log files
- One source feeds a "slow" output (e.g., Loki hitting rate limits)
- Another source feeds an independent output (e.g., Splunk)

**Example ClusterLogForwarder:**
```yaml
pipelines:
  # Pipeline 1: ALL application logs → Loki
  - name: default-logstore
    inputRefs: [application]
    outputRefs: [default-lokistack]
  
  # Pipeline 2: Specific namespace → Splunk
  - name: forward-mbas-a-to-splunk
    inputRefs: [mbas-a-application4splunk]
    outputRefs: [mbas-a-splunk]

inputs:
  - name: mbas-a-application4splunk
    type: application
    application:
      includes:
        - namespace: mbas-a-smps
      selector:
        matchLabels:
          logging: splunk-json
```

**Generated Vector sources (current broken behavior):**
```toml
# Global data_dir shared by ALL sources
data_dir = "/var/lib/vector/openshift-logging/cluster-log-forwarder"

[sources.input_application_container]
type = "kubernetes_logs"
# Reads ALL application logs including mbas-a-smps
# Feeds Loki output
# Uses global data_dir (shared checkpoint file)

[sources.input_mbas_a_application4splunk_container]
type = "kubernetes_logs"
include_paths_glob_patterns = ["/var/log/pods/mbas-a-smps_*/*/*.log"]
# Reads mbas-a-smps logs
# Feeds Splunk output
# Uses global data_dir (shared checkpoint file)
```

**Both sources:**
- Read the **same physical log files** (`/var/log/pods/mbas-a-smps_*/*/*.log`)
- Share the **same checkpoint file** (`checkpoints.json` in global data_dir)
- Use identical `FileFingerprint` for the same files (content-based hash)

## Root Cause Analysis

### Vector 0.54 Regression

Between Vector 0.47 (working) and 0.54 (broken), the `FileServer::run()` function underwent major changes:

**Vector 0.47:**
```rust
// Synchronous run, blocking on send
pub fn run(...) {
    // ...
    let result = self.handle.block_on(chans.send(to_send));
}
```

**Vector 0.54:**
```rust
// Async run, awaits on send
pub async fn run(...) {
    // ...
    let result = chans.send(to_send).await;
}
```

**Hypothesis:**
When `chans.send().await` blocks due to downstream sink backpressure (Loki rate limiting), Vector 0.54's file reading logic **propagates this backpressure to the file level** rather than isolating it to the specific source/sink.

### Shared Checkpoint State

Multiple sources sharing checkpoints creates contention:

1. **Shared checkpoint file:**
   ```
   /var/lib/vector/openshift-logging/cluster-log-forwarder/checkpoints.json
   ```

2. **Checkpoint structure:**
   ```rust
   pub struct CheckpointsView {
       checkpoints: DashMap<FileFingerprint, FilePosition>,
       modified_times: DashMap<FileFingerprint, DateTime<Utc>>,
       removed_times: DashMap<FileFingerprint, DateTime<Utc>>,
   }
   ```

3. **Fingerprint collision:** Same file = same fingerprint across sources
   - `input_application_container` reads `/var/log/pods/mbas-a-smps_*/app.log`
   - `input_mbas_a_application4splunk_container` reads same file
   - Both generate fingerprint `abc123...` for that file
   - Both try to read/write checkpoint for fingerprint `abc123...`

4. **Blocking behavior:**
   - When Loki sink blocks, `input_application_container` cannot update checkpoints
   - Shared checkpoint file may be locked or in inconsistent state
   - `input_mbas_a_application4splunk_container` reading same file is affected
   - File reading stops across ALL sources sharing that checkpoint

## Solution Design

### Approach: Per-Source Data Directories

**Isolate checkpoint state** by configuring a unique `data_dir` for each `kubernetes_logs` source.

### Data Directory Structure

**Base data path** (existing behavior):
```
GetDataPath(namespace, forwarderName) =
  - Legacy: /var/lib/vector (if namespace=openshift-logging, forwarder=cluster-log-forwarder)
  - Multi-CLF: /var/lib/vector/{namespace}/{forwarderName}
```

**Per-source subdirectories** (new):
```
{baseDataPath}/sources/{sourceName}/checkpoints.json
```

**Examples:**

| Scenario | Base Path | Source Name | Source Data Dir |
|----------|-----------|-------------|-----------------|
| Legacy | `/var/lib/vector` | `input_application_container` | `/var/lib/vector/sources/input_application_container` |
| Legacy | `/var/lib/vector` | `input_infrastructure_journal` | `/var/lib/vector/sources/input_infrastructure_journal` |
| Multi-CLF | `/var/lib/vector/app-ns/my-clf` | `input_application_container` | `/var/lib/vector/app-ns/my-clf/sources/input_application_container` |
| Multi-CLF | `/var/lib/vector/app-ns/my-clf` | `input_custom_app_container` | `/var/lib/vector/app-ns/my-clf/sources/input_custom_app_container` |

### Generated Vector Configuration

**After fix:**
```toml
# Global data_dir for non-source components (sinks, transforms)
data_dir = "/var/lib/vector/openshift-logging/cluster-log-forwarder"

[sources.input_application_container]
type = "kubernetes_logs"
data_dir = "/var/lib/vector/openshift-logging/cluster-log-forwarder/sources/input_application_container"
# Independent checkpoint: .../sources/input_application_container/checkpoints.json

[sources.input_mbas_a_application4splunk_container]
type = "kubernetes_logs"
data_dir = "/var/lib/vector/openshift-logging/cluster-log-forwarder/sources/input_mbas_a_application4splunk_container"
# Independent checkpoint: .../sources/input_mbas_a_application4splunk_container/checkpoints.json
```

### Benefits

✅ **Independent checkpoint state** - Each source tracks file positions independently  
✅ **Backpressure isolation** - Loki sink blocking cannot affect Splunk source  
✅ **Same file, multiple readers** - File can be read at different positions by different sources  
✅ **No Vector code changes** - Configuration-only fix  
✅ **Backward compatible** - Migration preserves existing checkpoint state  
✅ **Simple rollback** - Revert to shared checkpoint if needed  

### Trade-offs

⚠️ **File handle duplication** - Multiple sources = multiple file handles per log file  
⚠️ **Checkpoint storage** - ~10KB per source (negligible, typical: 10-15 sources = 150KB)  
⚠️ **Checkpoint bloat** - Each checkpoint contains entries for ALL files (cleaned up over time)  
⚠️ **Migration complexity** - Requires init container to copy checkpoints on upgrade  

## Implementation

### Component 1: Add DataDir Field to KubernetesLogs

**File:** `cluster-logging-operator/internal/generator/vector/api/sources/kubernetes_log_source.go`

```go
type KubernetesLogs struct {
	Type                      types.SourceType           `json:"type" yaml:"type" toml:"type"`
	DataDir                   string                     `json:"data_dir,omitempty" yaml:"data_dir,omitempty" toml:"data_dir,omitempty"` // NEW
	MaxReadBytes              uint                       `json:"max_read_bytes,omitempty" yaml:"max_read_bytes,omitempty" toml:"max_read_bytes,omitempty"`
	// ... rest of fields
}
```

### Component 2: Set Per-Source DataDir During Generation

**File:** `cluster-logging-operator/internal/generator/vector/adapters/input.go` (or equivalent)

```go
func (input *Input) Sources(baseDataDir string) (api.Sources, error) {
	sources := api.Sources{}
	
	sourceName := fmt.Sprintf("input_%s_container", input.Name())
	perSourceDataDir := path.Join(baseDataDir, "sources", sourceName)
	
	source := sources.NewKubernetesLogs(func(k *sources.KubernetesLogs) {
		k.DataDir = perSourceDataDir  // Set per-source data_dir
		k.MaxReadBytes = 3145728
		// ... rest of config
	})
	
	sources.Add(sourceName, source)
	return sources, nil
}
```

### Component 3: Checkpoint Migration Init Container

**Purpose:** Copy existing shared checkpoint to per-source directories on upgrade

**File:** `cluster-logging-operator/internal/factory/migrate-checkpoints.sh` (embedded)

```bash
#!/bin/sh
set -e

# Configuration from environment variables:
# VECTOR_BASE_DATA_DIR: /var/lib/vector/openshift-logging/cluster-log-forwarder
# VECTOR_SOURCE_NAMES: "input_application_container input_infrastructure_container ..."

SHARED_CHECKPOINT="$VECTOR_BASE_DATA_DIR/checkpoints.json"
MIGRATION_MARKER="$VECTOR_BASE_DATA_DIR/.migration-v1-done"
SOURCES_DIR="$VECTOR_BASE_DATA_DIR/sources"

echo "=== Vector Checkpoint Migration ==="
echo "Base directory: $VECTOR_BASE_DATA_DIR"

# Check if already migrated
if [ -f "$MIGRATION_MARKER" ]; then
    echo "Migration already completed"
    exit 0
fi

# Fresh install - no shared checkpoint
if [ ! -f "$SHARED_CHECKPOINT" ]; then
    echo "No shared checkpoint - fresh install"
    mkdir -p "$SOURCES_DIR"
    touch "$MIGRATION_MARKER"
    exit 0
fi

# Migrate checkpoints
echo "Migrating checkpoints to per-source directories..."
mkdir -p "$SOURCES_DIR"

for SOURCE_NAME in $VECTOR_SOURCE_NAMES; do
    SOURCE_DIR="$SOURCES_DIR/$SOURCE_NAME"
    mkdir -p "$SOURCE_DIR"
    
    if [ ! -f "$SOURCE_DIR/checkpoints.json" ]; then
        cp "$SHARED_CHECKPOINT" "$SOURCE_DIR/checkpoints.json"
        echo "  ✓ Migrated $SOURCE_NAME"
    else
        echo "  - $SOURCE_NAME (already exists)"
    fi
done

touch "$MIGRATION_MARKER"
echo "Migration complete - migrated $(echo $VECTOR_SOURCE_NAMES | wc -w) sources"
```

**File:** `cluster-logging-operator/internal/factory/daemonset.go`

```go
package factory

import (
	_ "embed"
	// ... other imports
)

//go:embed migrate-checkpoints.sh
var migrateCheckpointsScript string

func NewDaemonSet(..., clf *observability.ClusterLogForwarder, ...) *apps.DaemonSet {
	// ... existing construction
	
	sourceNames := collectSourceNames(clf)
	baseDataDir := vector.GetDataPath(namespace, resNames.ForwarderName)
	
	migrationContainer := corev1.Container{
		Name:    "migrate-checkpoints",
		Image:   collectorImage,
		Command: []string{"/bin/sh"},
		Args:    []string{"-c", migrateCheckpointsScript},
		Env: []corev1.EnvVar{
			{Name: "VECTOR_BASE_DATA_DIR", Value: baseDataDir},
			{Name: "VECTOR_SOURCE_NAMES", Value: strings.Join(sourceNames, " ")},
		},
		VolumeMounts: []corev1.VolumeMount{
			{Name: "vector-data", MountPath: "/var/lib/vector"},
		},
		SecurityContext: &corev1.SecurityContext{
			AllowPrivilegeEscalation: pointer.Bool(false),
			Capabilities: &corev1.Capabilities{Drop: []corev1.Capability{"ALL"}},
			RunAsNonRoot: pointer.Bool(true),
		},
		Resources: corev1.ResourceRequirements{
			Requests: corev1.ResourceList{
				corev1.ResourceMemory: resource.MustParse("32Mi"),
				corev1.ResourceCPU:    resource.MustParse("10m"),
			},
			Limits: corev1.ResourceList{
				corev1.ResourceMemory: resource.MustParse("64Mi"),
				corev1.ResourceCPU:    resource.MustParse("100m"),
			},
		},
	}
	
	ds.Spec.Template.Spec.InitContainers = append(
		ds.Spec.Template.Spec.InitContainers,
		migrationContainer,
	)
	
	return ds
}

func collectSourceNames(clf *observability.ClusterLogForwarder) []string {
	sourceNames := []string{}
	seen := make(map[string]bool)
	
	builtInSources := map[string][]string{
		"application":    {"input_application_container"},
		"infrastructure": {"input_infrastructure_container", "input_infrastructure_journal"},
		"audit": {
			"input_audit_host",
			"input_audit_kube",
			"input_audit_openshift",
			"input_audit_ovn",
		},
	}
	
	// Collect from pipelines
	for _, pipeline := range clf.Spec.Pipelines {
		for _, inputRef := range pipeline.InputRefs {
			if sources, found := builtInSources[inputRef]; found {
				for _, sourceName := range sources {
					if !seen[sourceName] {
						sourceNames = append(sourceNames, sourceName)
						seen[sourceName] = true
					}
				}
			}
		}
	}
	
	// Custom inputs
	for _, input := range clf.Spec.Inputs {
		if input.Type == observability.InputTypeApplication {
			sourceName := fmt.Sprintf("input_%s_container", input.Name)
			if !seen[sourceName] {
				sourceNames = append(sourceNames, sourceName)
				seen[sourceName] = true
			}
		}
	}
	
	return sourceNames
}
```

## Migration Strategy

### Upgrade Path

**Phase 1: Deploy operator with fix**
- Operator generates new Vector config with per-source `data_dir` fields
- DaemonSet includes migration init container
- Rolling update triggered

**Phase 2: Init container runs (per node)**
1. Check for migration marker (`.migration-v1-done`)
2. If marker exists → skip (already migrated)
3. If no shared checkpoint → fresh install, create marker, exit
4. If shared checkpoint exists:
   - Create `sources/` directory structure
   - Copy shared checkpoint to each source directory
   - Create migration marker

**Phase 3: Vector starts**
- Each `kubernetes_logs` source uses its own checkpoint
- Resumes from previous file positions (no log loss)
- Independent checkpoint updates per source
- Backpressure in one source doesn't affect others

### Idempotency

Migration is safe to run multiple times:
- ✅ Marker file prevents re-migration
- ✅ Skip if per-source checkpoint already exists
- ✅ No data corruption risk (copy operation, no modification)
- ✅ Pod restart during migration resumes from checkpoint

### Rollback

**Scenario:** Regression discovered, must rollback

**Option 1: Keep per-source checkpoints (recommended)**
- Revert operator to previous version
- Old Vector config uses global `data_dir`
- Per-source checkpoints ignored (not in config)
- Shared checkpoint still exists (not deleted by migration)
- Minor risk: re-reads logs since migration (bounded by checkpoint age)

**Option 2: Restore shared checkpoint from per-source**
```bash
# Manual recovery if shared checkpoint was deleted
oc exec -n openshift-logging ds/collector -- \
  cp /var/lib/vector/openshift-logging/cluster-log-forwarder/sources/input_application_container/checkpoints.json \
     /var/lib/vector/openshift-logging/cluster-log-forwarder/checkpoints.json
```

## Testing

### Unit Tests (BDD with Ginkgo/Gomega)

**File:** `internal/generator/vector/api/sources/kubernetes_log_source_test.go`
```go
var _ = Describe("KubernetesLogs", func() {
	Context("when creating source with data_dir", func() {
		It("should set data_dir correctly", func() {
			source := sources.NewKubernetesLogs(func(k *sources.KubernetesLogs) {
				k.DataDir = "/var/lib/vector/ns/clf/sources/input_app_container"
			})
			Expect(source.DataDir).To(Equal("/var/lib/vector/ns/clf/sources/input_app_container"))
		})
	})
})
```

**File:** `internal/factory/daemonset_test.go`
```go
var _ = Describe("DaemonSet migration init container", func() {
	Context("when generating DaemonSet", func() {
		It("should include migrate-checkpoints init container", func() {
			ds := NewDaemonSet(...)
			migrationContainer := findInitContainer(ds, "migrate-checkpoints")
			Expect(migrationContainer).ToNot(BeNil())
		})
		
		It("should set VECTOR_BASE_DATA_DIR correctly for legacy install", func() {
			ds := NewDaemonSet("collector", "openshift-logging", "cluster-log-forwarder", ...)
			env := findEnvVar(findInitContainer(ds, "migrate-checkpoints"), "VECTOR_BASE_DATA_DIR")
			Expect(env.Value).To(Equal("/var/lib/vector"))
		})
		
		It("should set VECTOR_SOURCE_NAMES with all sources", func() {
			// Test source name collection
		})
	})
})
```

### Integration Tests

**Test: Fresh install (no migration needed)**
```bash
# Deploy CLO + CLF
oc apply -f cluster-logging-operator.yaml
oc apply -f cluster-log-forwarder.yaml

# Verify init container logs
oc logs -n openshift-logging ds/collector -c migrate-checkpoints
# Expected: "No shared checkpoint - fresh install"

# Verify per-source dirs created
oc exec -n openshift-logging ds/collector -- \
  ls /var/lib/vector/openshift-logging/cluster-log-forwarder/sources/
```

**Test: Upgrade with checkpoint migration**
```bash
# Deploy old CLO, accumulate checkpoints
oc apply -f old-operator.yaml
sleep 300

# Capture shared checkpoint
oc exec ds/collector -- cat .../checkpoints.json > old-checkpoint.json

# Upgrade to fixed operator
oc apply -f new-operator.yaml
oc rollout status ds/collector

# Verify migration
oc logs ds/collector -c migrate-checkpoints | grep "Migration complete"

# Verify checkpoints copied
oc exec ds/collector -- ls .../sources/*/checkpoints.json

# Compare content
oc exec ds/collector -- cat .../sources/input_application_container/checkpoints.json > new-checkpoint.json
diff old-checkpoint.json new-checkpoint.json
```

**Test: Reproduce LOG-9871 (verify fix)**
```bash
# Deploy CLF with Loki + Splunk outputs
oc apply -f multi-output-clf.yaml

# Deploy log-generating app
oc apply -f springboot-app.yaml

# Trigger log spike (restart app)
oc delete pod -l app=springboot

# Monitor for Loki 429 errors
oc logs ds/collector | grep "429 Too Many Requests"

# VERIFY: Splunk continues receiving logs (should NOT stop)
# Query Splunk: index=openshift namespace=mbas-a-* | stats count
# Expected: count increasing (logs still arriving)

# VERIFY: Loki recovers after backoff
oc logs ds/collector | grep "Retrying after error" | tail
```

### Shell Script Tests

**File:** `internal/factory/migrate-checkpoints_test.sh`
```bash
#!/bin/bash
# Standalone tests for migration script

test_fresh_install() {
    TEST_DIR=$(mktemp -d)
    export VECTOR_BASE_DATA_DIR="$TEST_DIR"
    export VECTOR_SOURCE_NAMES="input_app_container"
    
    sh migrate-checkpoints.sh
    
    [ -d "$TEST_DIR/sources" ] || exit 1
    [ -f "$TEST_DIR/.migration-v1-done" ] || exit 1
    echo "PASS: Fresh install"
}

test_migration() {
    TEST_DIR=$(mktemp -d)
    echo '{"version":"1","checkpoints":[]}' > "$TEST_DIR/checkpoints.json"
    
    export VECTOR_BASE_DATA_DIR="$TEST_DIR"
    export VECTOR_SOURCE_NAMES="input_app input_infra"
    
    sh migrate-checkpoints.sh
    
    [ -f "$TEST_DIR/sources/input_app/checkpoints.json" ] || exit 1
    [ -f "$TEST_DIR/sources/input_infra/checkpoints.json" ] || exit 1
    echo "PASS: Migration"
}

test_idempotent() {
    TEST_DIR=$(mktemp -d)
    echo '{}' > "$TEST_DIR/checkpoints.json"
    
    export VECTOR_BASE_DATA_DIR="$TEST_DIR"
    export VECTOR_SOURCE_NAMES="input_app"
    
    sh migrate-checkpoints.sh
    OUTPUT=$(sh migrate-checkpoints.sh 2>&1)
    
    echo "$OUTPUT" | grep -q "already completed" || exit 1
    echo "PASS: Idempotent"
}
```

## File Handle Considerations

### Impact Analysis

**Multiple file handles per log file:**
- Each `kubernetes_logs` source opens files independently
- Overlapping sources = duplicate file handles

**Example:**
```
Log file: /var/log/pods/mbas-a-smps_pod1/app/0.log

Opened by:
  - input_application_container (Loki)    → 1 handle
  - input_mbas_a_splunk_container (Splunk) → 1 handle
Total: 2 handles for 1 file
```

**Scale estimate:**
- 100 pods × 2 containers = 200 log files
- 2 overlapping sources = 400 file handles
- Plus infrastructure/audit sources = **~500-600 total handles**

**Limit check:**
```bash
# In Vector container
ulimit -n          # Often 1024 or 65536
cat /proc/$(pgrep vector)/limits | grep "open files"
```

### Mitigation

**Current approach:**
- Acceptable for typical deployments (within default 1024-65536 limits)
- Monitor file handle usage in production
- Add metrics/alerts if approaching limits

**Future optimization (if needed):**
- Single source + routing architecture (reads file once, routes to multiple outputs)
- Requires CLO refactoring - candidate for 6.7+ enhancement

## Success Criteria

✅ Logs continue forwarding to Splunk when Loki hits rate limits  
✅ Loki recovers after backoff without pod restart  
✅ No log duplication during upgrade  
✅ No log loss during upgrade  
✅ Migration completes on all nodes  
✅ File handle usage within limits  
✅ Rollback works without data loss  

## Files Modified

### cluster-logging-operator

| File | Change | LOC |
|------|--------|-----|
| `internal/generator/vector/api/sources/kubernetes_log_source.go` | Add `DataDir` field | ~3 |
| `internal/generator/vector/adapters/input.go` | Set per-source data_dir | ~25 |
| `internal/generator/vector/conf/conf.go` | Pass baseDataDir to adapters | ~10 |
| `internal/factory/migrate-checkpoints.sh` | Embedded migration script | ~40 |
| `internal/factory/daemonset.go` | Add init container, collectSourceNames | ~120 |
| `internal/generator/vector/api/sources/kubernetes_log_source_test.go` | BDD tests for DataDir | ~40 |
| `internal/factory/daemonset_test.go` | BDD tests for init container | ~180 |
| `internal/factory/migrate-checkpoints_test.sh` | Shell script tests (optional) | ~80 |

**Total:** ~500 lines

## Timeline

- Implementation: 3-5 days
- Unit testing: 2 days
- Integration testing: 2-3 days
- Scale/performance testing: 1-2 days
- **Total: 8-12 days**

## References

- **Issue:** https://redhat.atlassian.net/browse/LOG-9871
- **Related:** LOG-9442 (Vector stops sending), LOG-9443 (Vector stops collecting)
- **Vector source:** `vectordotdev/vector` v0.54.0
- **Vector FileServer:** `lib/file-source/src/file_server.rs`
- **Vector Checkpointer:** `lib/file-source-common/src/checkpointer.rs`

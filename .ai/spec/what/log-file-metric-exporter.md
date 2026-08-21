# Log File Metric Exporter

The Log File Metric Exporter is a standalone Prometheus exporter that watches Kubernetes pod log files on each node and publishes a counter of bytes written. It provides a ground-truth measurement of how much data pods actually log, independent of what the collector (Vector) manages to ingest — so operators can detect collector lag or loss.

The exporter is deployed as a DaemonSet by the Red Hat OpenShift Logging Operator (CLO) in response to a `LogFileMetricExporter` CR. CLO owns the CRD and reconciliation; this component is the binary that runs in the DaemonSet pods. The exporter binary lives in its own repository (`github.com/ViaQ/log-file-metric-exporter`), analogous to how Vector is a separate collector binary deployed by CLO.

## Behavioral Rules

### Metric Contract

1. The exporter publishes exactly one metric: `log_logged_bytes_total`, a Prometheus counter measured in bytes. `[GA]`
2. The metric carries four labels, all lowercase: `namespace`, `podname`, `poduuid`, `containername`. `[GA]`
3. High-cardinality labels are avoided by design — pod identity is expressed via `poduuid`, not per-record unique IDs. `[GA]`
4. Metrics are served over HTTPS at `/metrics` (default `:2112`). `[GA]`

### Byte Counting Semantics

5. When a watched log file grows, the delta (`newSize - lastSize`) is added to the counter. `[GA]`
6. When a watched log file is truncated (`newSize < lastSize`, indicating rotation), the new size is added to the counter, so bytes written after rotation are counted without double-counting. `[GA]`
7. When a watched log file is deleted or disappears, its metric labels and size tracking are dropped (`Forget`), so stale series are not retained. `[GA]`

### File Discovery

8. The exporter watches a configurable directory (default `/var/log/pods`) for file size changes using filesystem notifications. `[GA]`
9. Log file paths are parsed against the Kubernetes convention `<namespace>_<podname>_<uuid>/<container>/*.log` to extract the metric labels; paths that do not match are ignored. `[GA]`
10. Kubernetes stores pod logs as symlinks whose targets change on rotation; the exporter watches symlink targets and subdirectories recursively and re-targets watches when symlinks change, so rotation events are not missed. `[GA]`

### Authentication

11. When secure metrics are enabled (`-secureMetrics=true`), the `/metrics` endpoint requires a valid bearer token in the `Authorization` header. `[GA]`
12. Bearer tokens are validated via the Kubernetes TokenReview API and authorized via SubjectAccessReview (checking `GET` on the request path) before metrics are served. `[GA]`

## Configuration Surface

The exporter is configured via command-line flags (set by CLO when it renders the DaemonSet):

| Flag | Default | Description |
|---|---|---|
| `-dir` | `/var/log/pods` | Directory watched for pod log files |
| `-http` | `:2112` | Address the metrics HTTP(S) server binds to |
| `-crtFile` | `/etc/logfilemetricexporter/metrics/tls.crt` | TLS certificate file |
| `-keyFile` | `/etc/logfilemetricexporter/metrics/tls.key` | TLS private key file |
| `-tlsMinVersion` | — | Minimum TLS version (e.g. `VersionTLS12`, `VersionTLS13`) |
| `-cipherSuites` | — | Comma-separated OpenSSL cipher suite names |
| `-groups` | — | TLS key-exchange groups/curves (e.g. `X25519,secp256r1,secp384r1`) |
| `-secureMetrics` | `false` | Require a valid bearer token to scrape metrics |
| `-verbosity` | `0` | Log verbosity level |

## Constraints

- The exporter depends on the OpenShift/Kubernetes pod log layout under the watched directory; only the CRI-O log path convention on OpenShift nodes is supported.
- The metric name and label set are a public contract — Prometheus scrape configs, dashboards, and alerts depend on them. Changing them is a breaking change that must be coordinated with CLO (which renders the ServiceMonitor/scrape config) and the docs.
- The exporter exposes only its own byte-counting metric; it does not read, forward, or transform log content.

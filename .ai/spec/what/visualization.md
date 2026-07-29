# Visualization

The Logging UI Plugin extends the OpenShift Console with log exploration capabilities. It is deployed via the Cluster Observability Operator (COO) `UIPlugin` CR. The plugin connects to a LokiStack backend and provides query, filtering, and alerting views.

## Behavioral Rules

### Deployment

1. The Logging UI Plugin is deployed by creating a `UIPlugin` CR with `type: Logging` via the Cluster Observability Operator. `[GA, via COO support exception]`
2. COO itself is Technology Preview, but the Logging UI Plugin has a support exception making it GA for logging use on OCP 4.14+ with Logging 6.0+. `[TP with support exception]`

### Views and Navigation

3. **Logs page** (`/monitoring/logs`) is added to the admin perspective under Observe > Logs. `[GA]`
4. **Aggregated Logs tab** is added to Pod detail pages as a horizontal nav tab. `[GA]`
5. **Developer perspective Logs** — a logs tab in the developer perspective's Observe section. `[GA]` (requires `dev-console` feature flag)

### Query Features

6. LogQL query input for searching and filtering logs. `[GA]`
7. Time range selection with predefined and custom ranges. `[GA]`
8. Auto-refresh interval configuration. `[GA]`
9. Multi-tenant selector (application, infrastructure, audit). `[GA]`
10. Log histogram visualization showing log volume over time. `[GA]`
11. Virtualized log table with expandable log detail view. `[GA]`
12. Query statistics display. `[GA]`
13. Streaming (live tail) toggle. `[GA]`

### Filtering

14. Attribute-based filtering (namespace, severity, etc.). `[GA]`

### Data Model Support

15. The plugin supports two log data models: `otel` (OpenTelemetry) and `viaq` (ViaQ/traditional). `[GA]`
16. The `schema` field on the UIPlugin CR controls which data model the UI uses: `otel`, `viaq`, or `select` (shows a dropdown for the user to choose). `[GA]` (`otel` and `select` require OCP 4.15+)

### Alert Integration

17. Log-based alerting rules from Loki ruler are merged into the OpenShift Console alerts view (admin perspective). `[GA]` (requires `alerts` feature flag)
18. Log-based alerting rules are also available in the developer perspective. `[GA]` (requires `dev-alerts` feature flag)
19. Log-based alert metrics chart component. `[GA]`

### Timezone

20. Timezone selector for log timestamps. `[GA]`

## Configuration Surface

| Field | Type | Default | Description |
|---|---|---|---|
| UIPlugin `spec.logging.logsLimit` | int | — | Maximum number of log entries to fetch |
| UIPlugin `spec.logging.timeout` | string | — | Query timeout |
| UIPlugin `spec.logging.schema` | enum | `viaq` | `otel`, `viaq`, or `select` |
| UIPlugin `spec.logging.alertingRuleTenantLabelKey` | string | — | Label key for tenant in alerting rules |
| UIPlugin `spec.logging.alertingRuleNamespaceLabelKey` | string | — | Label key for namespace in alerting rules |
| UIPlugin `spec.logging.useTenantInHeader` | bool | — | Send tenant via header instead of URL |
| UIPlugin `spec.logging.showTimezoneSelector` | bool | — | Show timezone dropdown |
| CLI `-features` | string | — | Feature flags: `dev-console`, `alerts`, `dev-alerts` |

## Constraints

- The Logging UI Plugin requires a LokiStack backend — it queries Loki via LogQL.
- The plugin is deployed as a dynamic console plugin using OpenShift Console's Module Federation.
- OCP 4.15+ is required for `otel` or `select` schema modes.
- The COO support exception applies only when using the Logging UI Plugin for logging — other COO features remain TP.

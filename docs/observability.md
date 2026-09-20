# Mithril observability

Mithril uses PromEx for application metrics and Fly.io's managed Prometheus-compatible metrics store and Grafana for operational dashboards.

## Architecture

```text
Mithril
  |
  | PromEx telemetry
  v
private metrics server :9091/metrics
  |
  | Fly internal scrape every ~15s
  v
Fly managed Prometheus
  |
  v
Fly managed Grafana
```

The public Phoenix API remains on port 4000. Port 9091 is not declared as a public Fly service, so `/metrics` is not exposed through `api.tryinstaclean.com` or the staging API hostname.

Fly configuration:

```toml
[metrics]
  port = 9091
  path = "/metrics"
```

## Metrics collected

PromEx collects:

- application/dependency information
- BEAM memory, schedulers, process counts, reductions, and runtime information
- Phoenix request counts and request latency, including router/controller/action labels
- Ecto query counts and query latency
- Oban job, producer, circuit, and queue metrics

Phoenix channel/socket metric groups are disabled because Mithril does not currently use them.

The PromEx polling interval for BEAM and Oban is 15 seconds to align with Fly's custom metric scrape cadence and avoid unnecessary churn.

## Grafana

Open the Fly.io Metrics dashboard for the Mithril app, then open managed Grafana/Explore with the Fly Prometheus datasource.

PromEx metric names use the `mithril_prom_ex_` prefix. The included PromEx dashboard definitions are:

- `application.json`
- `beam.json`
- `phoenix.json`
- `ecto.json`
- `oban.json`

They can be rendered with PromEx tooling if a standalone Grafana dashboard import is desired.

## What to watch first

### API health

Use the Phoenix metrics to watch:

- request volume
- p50/p95/p99 latency
- 4xx/5xx rates
- slow controllers/actions
- booking, payment, auth, WhatsApp, and Direct admin endpoint traffic

Fly's built-in proxy metrics remain useful for edge-level response status and latency.

### Database

Use Ecto metrics for:

- query latency
- queue time
- decode/query time
- unusually slow database operations

### Background jobs

Use Oban metrics for:

- queue depth
- job duration
- failures/discards
- retries
- producer health

The current `notifications` queue and booking-reminder jobs are covered automatically.

### Booking and dispatch

For the first iteration, booking and dispatch observability comes from Phoenix route/controller/action labels. This avoids adding duplicate high-cardinality business counters before we know which operational questions actually matter.

If route-level metrics are not enough, add explicit low-cardinality Mithril business telemetry next, for example:

- booking creation success/failure
- payment verification failure
- replacement request creation
- cleaner assignment latency

Do not label Prometheus metrics with booking IDs, user IDs, phone numbers, emails, addresses, payment references, or other high-cardinality/customer data.

## Local development

PromEx runs on:

```text
http://localhost:9091/metrics
```

The Phoenix app remains on port 4000.

PromEx is disabled under `MIX_ENV=test` so ExUnit runs do not compete for a metrics port.

## PostHog

PostHog remains the product analytics layer. It should track product behavior such as funnel steps, feature usage, and conversion. PromEx/Grafana are for operating Mithril itself.

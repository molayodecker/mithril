# Mithril observability

Mithril uses PromEx for application metrics. Fly.io scrapes those metrics into managed Prometheus. Grafana reads Fly Prometheus; Mithril does not push dashboards or talk to Grafana itself.

Keep PromEx Grafana disabled in Mithril:

```elixir
grafana: :disabled
```

## Architecture

```text
Mithril
  ↓
PromEx :9091/metrics
  ↓
Fly Prometheus
  ↓
Grafana (fly-metrics.net, or any Grafana pointed at Fly Prometheus)
```

The public Phoenix API remains on port 4000. Mithril serves `PromEx.Plug` from a dedicated Bandit listener on `0.0.0.0:9091` (`ip: :any`) so Fly's internal scraper can reach it. Port 9091 is not declared as a public Fly service, so `/metrics` is not exposed through `api.tryinstaclean.com` or the staging API hostname. This reuses Mithril's existing Bandit server dependency instead of adding Cowboy solely for metrics.

Fly configuration:

```toml
[metrics]
  port = 9091
  path = "/metrics"
```

## Grafana

The Grafana instance we already have is Fly's managed Grafana at [fly-metrics.net](https://fly-metrics.net). It is preconfigured with this organization's Prometheus datasource. Sign in with the Fly account that owns the `personal` org. No Mithril Grafana token, PromEx Grafana plugin, or extra datasource is required there.

Fly organization slug: `personal`

Prometheus URL (org-scoped, already wired in fly-metrics.net):

```text
https://api.fly.io/prometheus/personal/
```

Fly attaches `app`, `region`, `host`, and `instance` labels. Separate environments with:

```promql
{app="instaclean-mithril"}
```

```promql
{app="instaclean-mithril-staging"}
```

PromEx series use the `mithril_prom_ex_` prefix and only appear after a deploy that includes PromEx (`[metrics]` scrape of `:9091/metrics`). Until then, Explore still has Fly built-in series such as `fly_instance_up`, `fly_instance_cpu`, `fly_instance_memory_*`, and `fly_edge_http_responses_count`.

After [PR #40](https://github.com/molayodecker/mithril/pull/40) is on staging, build a **Mithril Overview** dashboard in fly-metrics.net with API rate/latency/errors, BEAM memory, Ecto query latency, Oban failures/queue depth, Fly CPU/memory, and a staging vs production variable.

Included PromEx dashboard JSON (import later if wanted; do not auto-upload from the app):

- `application.json`
- `beam.json`
- `phoenix.json`
- `ecto.json`
- `oban.json`

### Optional: Grafana Cloud or self-hosted Grafana

Only needed if we stop using fly-metrics.net. Add a Prometheus datasource in Grafana:

```text
Name:
Mithril - Fly Prometheus

Prometheus server URL:
https://api.fly.io/prometheus/personal/

Scrape interval:
15s

Custom HTTP Header:
Authorization

Value:
FlyV1 <token from `fly tokens create readonly -o personal`>
```

Put the token only in Grafana's secure credential field. Do not commit it, put it in `.env`, or send it in chat.

Use `FlyV1` for tokens created with `fly tokens create`. Use `Bearer` for the token returned by `flyctl auth token`. The authorization scheme must match the token source. Leave Grafana auth type as none / no basic auth; the custom header is the credential.

Save & test should report a successful Prometheus API query. Grafana can then use the datasource for Explore, dashboards, alerting, annotations, and recording rules.

## Metrics collected

PromEx collects:

- application/dependency information
- BEAM memory, schedulers, process counts, reductions, and runtime information
- Phoenix request counts and request latency, including router/controller/action labels
- Ecto query counts and query latency
- Oban job, producer, circuit, and queue metrics

Phoenix channel/socket metric groups are disabled because Mithril does not currently use them.

The PromEx polling interval for BEAM and Oban is 15 seconds to align with Fly's custom metric scrape cadence and avoid unnecessary churn.

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

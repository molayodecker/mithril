# Mithril 12-Factor Operating Baseline

Mithril follows the 12-Factor methodology as an operational baseline for Phoenix on Fly.io. The goal is repeatable deploys, replaceable infrastructure, stateless application Machines, and durable business state.

## Rules

### One codebase, many deploys

`molayodecker/mithril` is the application codebase. Development, test, staging, and production must run the same code and differ through runtime configuration.

### Explicit dependencies

Application dependencies belong in `mix.exs`. Runtime system dependencies belong in the production container image. Do not depend on packages installed manually on a Fly Machine.

### Runtime configuration only

Deploy-specific configuration comes from environment variables.

Secrets must use Fly secrets or an equivalent secret manager. Non-sensitive runtime values may live in `fly.toml`.

Production currently requires:

- `DATABASE_BACKEND` (`fly` or `supabase`)
- `FLY_DATABASE_URL` when `DATABASE_BACKEND=fly`
- `SUPABASE_DATABASE_URL` or `DATABASE_URL` when `DATABASE_BACKEND=supabase`
- `SECRET_KEY_BASE`
- `PHX_HOST`

Optional/tunable values include:

- `PORT`
- `POOL_SIZE`
- `ECTO_IPV6`
- `MITHRIL_PARITY_TOKEN` during migration only

Do not read configuration files from the Machine filesystem and do not hardcode provider credentials, database hosts, or environment-specific URLs in application code.

### Backing services are attached resources

PostgreSQL, Cloudflare R2, Paystack, messaging providers, telemetry services, and future infrastructure integrations are resources attached through configuration. Business contexts should not depend on provider-specific URLs when a stable internal identifier can be stored instead.

During migration, Mithril can serve either Fly Managed Postgres or Supabase. `DATABASE_BACKEND` selects the active URL. Live Instaclean data can still be copied from Supabase onto Fly with `scripts/db_sync_from_live.sh`. Switching providers is configuration, not a rewrite of application code.

### Build, release, run are separate

The production Docker image is the immutable build artifact. Runtime secrets are not baked into that image.

Do not run destructive database migration work automatically during container build or application boot. While Supabase remains the canonical schema owner, Mithril intentionally has no Fly release migration command.

When Mithril eventually owns migrations, they must run as an explicit release/admin phase before the new application version serves traffic.

### Stateless application processes

Fly Machines are disposable. Their local filesystems and BEAM process memory are never the only source of durable business state.

Durable state belongs in PostgreSQL or another explicitly durable backing service. This includes:

- bookings and booking transitions
- users and cleaner identity mappings
- pricing and discounts
- payments, refunds, payouts, and wallets
- availability state that must survive restarts
- notification delivery state and idempotency records
- scheduled work and retry state

GenServers, ETS, Agents, Phoenix Presence, and caches may hold derived, temporary, or reconstructable state only.

### Port binding

Phoenix binds directly to the runtime `PORT`. Fly routes traffic to that port. No host-installed web server is required.

### Concurrency and scale-out

Scale application capacity by adding BEAM concurrency and Fly Machines rather than by making one Machine authoritative.

Code must assume another request can be handled on another Machine. Cross-Machine coordination that matters to correctness must use PostgreSQL or another durable coordination mechanism.

Phoenix PubSub may be used for realtime delivery, but realtime messages are not durable state.

### Disposability

Mithril must start cleanly from runtime configuration and backing services alone.

Fly sends `SIGTERM`, and `fly.toml` provides a 30-second graceful-shutdown window. Request handlers and future workers must stop accepting new work, finish or checkpoint safely, and release resources cleanly.

### Development/production parity

Keep local/CI PostgreSQL behavior close to production and test application behavior against the legacy schema during migration. Avoid development-only shortcuts that change transaction or authorization semantics.

### Logs are event streams

Application logs go to stdout/stderr through Elixir Logger. Do not write production log files to the Machine filesystem. Fly or attached observability systems collect the stream.

Never log secrets, database URLs, signed URLs, tokens, private identity documents, or sensitive payment payloads.

### Admin processes are one-off processes

Backfills, reconciliations, restore rehearsals, maintenance commands, and future database migrations run as explicit one-off release/admin commands using the same application code and runtime configuration as the deployed app.

Do not hide operational mutations in application startup callbacks.

## Instaclean-specific guardrails

1. PostgreSQL is the durable source of truth for transactional state.
2. Do not use a GenServer/Agent/ETS table as the authoritative booking, payment, payout, or job queue store.
3. Background work that must survive restarts must eventually use a durable queue backed by PostgreSQL. Oban is the preferred direction once background-job migration begins.
4. Payment/webhook/message handlers must be idempotent.
5. Never persist important data only to Fly Machine disk.
6. Never bake secrets into Docker images or `fly.toml`.
7. Provider integrations must be configurable and replaceable at their boundaries.
8. Database cutover and application deployment remain separate operations until the Supabase migration is complete. `DATABASE_BACKEND` is the Mithril connection switch. API clients such as Direct authenticate with Mithril JWTs (`POST /auth/login`); web/mobile can keep Supabase Auth until those clients are cut over.

## Review checklist

Before merging a new backend feature, ask:

- Does correctness survive a Machine restart?
- Does correctness survive two Machines handling requests concurrently?
- Is every deploy-specific value runtime configuration?
- Is durable state stored in a durable backing service?
- Is retryable external work idempotent?
- Does the feature log to stdout/stderr without leaking secrets?
- Can the same image run in another environment by changing configuration only?

If the answer to any of these is no, the feature needs an architectural exception or a redesign before production use.

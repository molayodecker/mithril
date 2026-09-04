# Supabase → Mithril migration

## Goal

Move Instaclean backend behavior from the private `instaclean-schema` Supabase project into Phoenix without interrupting web, mobile, WhatsApp, bookings, payments, notifications, or cleaner operations.

Baseline source commit: `d13b81e5ce5d5ede6a8884394791a5e274609095`.

## Non-goals for the first cut

- Do not copy the private Supabase repository wholesale into public Mithril.
- Do not change the production database schema merely to make it look more Ecto-native.
- Do not replace authentication, storage, realtime, RPCs, Edge Functions, and cron in one release.
- Do not repoint the web/mobile `supabase` git submodules until Mithril actually owns the required behavior.

## Coexistence architecture

```text
Web / Mobile / WhatsApp
        |
        +----------------------+
        |                      |
   Supabase APIs            Mithril API
   (legacy paths)           (migrated paths)
        |                      |
        +----------+-----------+
                   |
              PostgreSQL
          existing source of truth
```

During coexistence, both stacks use the same data model. New Mithril code should prefer Ecto contexts and explicit transactions while preserving existing database constraints and RLS assumptions.

## Capability map

| Supabase capability | Mithril destination | Migration rule |
| --- | --- | --- |
| PostgreSQL tables | Ecto schemas / query modules | Map existing tables first; avoid unnecessary DDL |
| SQL RPC business logic | Phoenix contexts + `Ecto.Multi` | Move one RPC at a time with parity tests |
| Edge Functions | Controllers / context services | Preserve request/response contracts during cutover |
| Scheduled Edge Functions / pg_cron | Supervised/background jobs | Inventory first; move only after sync flows are stable |
| Realtime | Phoenix.PubSub / Channels | Migrate only consumers that need server push |
| Supabase Auth | Existing JWT validation first | Avoid forced account migration during backend cutover |
| Supabase Storage | Keep initially behind an adapter | Storage migration is independent of API migration |
| RLS | Existing DB policies during coexistence | Use a least-privilege Mithril DB role; do not silently bypass policy intent |

## Migration order

### Phase 0 — Foundation ✅

- Phoenix application boots.
- Ecto connects through `DATABASE_URL`.
- `/health` works.
- `/ready` verifies database connectivity and is used by Fly for service routing checks.
- CI runs formatting, warnings-as-errors compilation, and tests.
- Production credentials exist only in deployment secrets.

Foundation landed in Mithril on 2026-09-03.

### Phase 1 — Read-only parity 🚧

Start by mapping stable fields from the existing `public.bookings` table. The first endpoint is intentionally internal and protected by `MITHRIL_PARITY_TOKEN`:

```text
GET /internal/parity/bookings/:id
x-mithril-parity-token: <server-side token>
```

This route is for Supabase-vs-Mithril comparison only. It must not be wired directly to customer clients.

`MITHRIL_PARITY_TOKEN` must be in the shell (direnv loads it from `.env` when present). The production API hostname is `api.tryinstaclean.com`; `instaclean-mithril.fly.dev` remains a direct Fly fallback. Known production smoke-test booking:

```bash
curl \
  -H "x-mithril-parity-token: $MITHRIL_PARITY_TOKEN" \
  https://api.tryinstaclean.com/internal/parity/bookings/1aba469c-8dcb-4611-806e-6be74900ba86
```

Expected fields include `id`, `service_id` (integer), `status`, `total_price`, `platform_fee`, and `tax_amount`. Numeric database values are emitted as JSON numbers for this temporary parity API.

Fly Machine and request telemetry: [instaclean-mithril monitoring](https://fly.io/apps/instaclean-mithril/monitoring).

Continue read-only mappings for:

1. users/profiles
2. cleaners and availability
3. services/pricing
4. properties/addresses
5. schedule groups

No writes move yet. Compare results against existing RPC/API responses.

### Phase 2 — Booking vertical slice

Move the smallest complete booking path behind a feature flag:

- availability lookup
- quote/pricing calculation
- booking creation transaction
- cleaner assignment/acceptance state transitions
- customer/admin readback

Keep Paystack and existing notification side effects behind adapters so they can be invoked from either legacy or Mithril code during transition.

### Phase 3 — Payments and payouts

Move payment initialization, webhook handling, refunds, wallet credits, and payout state transitions only after booking idempotency and state-machine tests exist in Mithril.

### Phase 4 — Messaging and operations

Move WhatsApp, SMS, email, push notifications, reminders, broadcasts, and operational alerts. Background work should be idempotent and retry-safe.

### Phase 5 — Auth, realtime, storage

These are infrastructure migrations, not prerequisites for moving business logic. Handle them independently after the core API is stable.

### Phase 6 — Cutover

Before retiring `instaclean-schema`:

- all production callers for migrated capabilities use Mithril;
- no required Edge Function/RPC/cron traffic remains;
- rollback is documented and tested;
- monitoring covers latency, errors, queue failures, and DB saturation;
- web and mobile no longer depend on the Supabase submodule for runtime behavior.

## Database safety

Mithril must not use a superuser/service connection as its normal runtime role. Create a dedicated PostgreSQL role with only the privileges required by the application. Preserve constraints, triggers, and RLS semantics until equivalent authorization is enforced and reviewed in Phoenix.

Never run destructive Ecto migrations against production as part of application startup.

## First implementation target

The first target is read-only booking retrieval. It exercises the real data model without creating duplicate bookings, charging customers, or sending notifications. Availability comes next after the current availability RPC/table behavior is inventoried.

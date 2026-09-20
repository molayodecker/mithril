# Mithril Agent Engineering Rules

These instructions apply to coding agents working in this repository.

## Core expectation

Do not stop when the requested change compiles or existing tests pass. Review the surrounding workflow for behavioral bugs, stale state, unsafe transitions, missing authorization, concurrency problems, integration gaps, and partial-failure cases.

Before considering a meaningful coding task complete, ask:

> Can a sequence of individually valid requests or operations leave Mithril in an invalid business state?

If yes, fix it and add a regression test.

## Automatic high-risk classification

Treat a change as high-risk whenever it can affect:

- money, pricing, fees, discounts, refunds, or payment references
- booking lifecycle or service duration
- schedules, reservations, cleaner assignment, or dispatch
- authentication, authorization, identity, roles, or verification
- webhooks, callbacks, WhatsApp, email, push, or other external integrations
- notifications or jobs that can drive business state
- user-owned resources or sensitive data

High-risk classification is based on behavior, not only filenames.

For high-risk changes, perform the deeper review below before finishing.

## 1. State-transition integrity

Identify the state before and after the operation.

Check that the change cannot create impossible or inconsistent combinations, especially for bookings, payments, refunds, assignments, dispatch offers, cancellations, reschedules, verification, and notifications.

Examples:

- A paid booking must not allow price-affecting fields to change without an explicit payment adjustment.
- A cancelled booking must not remain dispatchable.
- A replaced, expired, or repriced payment attempt must not remain usable.
- A completed booking must not move back to an active state unless that workflow is explicitly supported.

Always ask:

> What data or state becomes stale after this operation?

## 2. Payment integrity

Treat payment code as security-sensitive.

Whenever price, service, duration, schedule, currency, fees, discounts, or payment references change, inspect every associated payment attempt.

Verify that:

- provider references belong to the intended booking
- amount and currency match canonical server-side values
- stale payment attempts cannot still settle
- retries are idempotent
- duplicate callbacks cannot double-charge or double-transition state
- paid bookings cannot silently gain additional service without payment
- booking state and provider state cannot drift silently

Prefer changing booking and payment state atomically in one database transaction when practical.

## 3. Client-controlled input

Assume fields from mobile, web, admin UI, webhooks, and external APIs can be manipulated.

Do not trust client-provided:

- prices
- user IDs
- booking ownership
- roles
- payment amounts
- payment references
- cleaner IDs
- status values
- timestamps
- verification flags

Recompute or verify sensitive values server-side.

## 4. Authorization and ownership

For every user-owned read or write, verify ownership or authorized staff access on the server.

Check both the happy path and cross-user attacks.

A customer must never be able to inspect, pay for, reschedule, cancel, or modify another customer's booking merely by supplying its UUID.

## 5. Concurrency and idempotency

Assume two requests can happen at the same time and external providers can retry callbacks.

Review for:

- duplicate bookings
- duplicate payments
- double cleaner assignment
- overlapping reservations
- repeated webhooks
- repeated cancellation or refund
- repeated notification jobs
- stale writes overwriting newer state

Prefer database constraints, row locks, transactions, exclusion constraints, unique indexes, and idempotency keys over check-then-write logic.

## 6. External integration completeness

For Twilio, Paystack, Stripe, email, push, storage, maps, and other providers, trace the complete round trip:

request -> provider -> webhook/callback -> database -> API/UI

Do not verify only the outbound request.

For messaging, verify outbound messages and inbound replies.

For payments, verify checkout initialization and provider verification/webhook reconciliation.

## 7. Data lifecycle

Whenever a value changes, identify dependent data that may now be stale.

Examples:

A booking reschedule may affect:

- reminder timestamps
- dispatch reservations
- payment attempts
- cached availability
- scheduled jobs
- cleaner availability

Changing a phone number may affect:

- WhatsApp threads
- SMS identity
- user matching

Changing a cleaner may affect:

- schedule reservations
- notifications
- earnings
- dispatch state

Updating only the primary row is not automatically sufficient.

## 8. Failure paths

Review what happens if each database or external operation fails midway.

Avoid partial state where one critical record is updated but related state is stale.

Prefer this shape where appropriate:

validate -> authorize -> lock -> mutate related state atomically -> commit -> perform safe asynchronous side effects

## 9. Database invariants

Prefer enforcing important invariants in PostgreSQL when practical.

Consider:

- foreign keys
- unique constraints
- exclusion constraints
- CHECK constraints
- transactions
- SELECT ... FOR UPDATE
- advisory locks

Application validation should complement database integrity, not replace it.

## 10. Observability and privacy

For new operational code, consider whether failures will be visible through structured logs and PromEx/Grafana.

Never put high-cardinality or sensitive values into Prometheus labels, including:

- user IDs
- booking IDs
- phone numbers
- emails
- addresses
- payment references

## 11. Dependency review

When adding a dependency:

- verify whether an existing dependency already provides the capability
- inspect important transitive dependencies
- check security advisories
- avoid adding a second server/client library without a strong reason

For example, if Mithril already uses Bandit, do not add Cowboy only to expose an internal metrics endpoint when Bandit can safely serve it.

## 12. Regression tests

Every confirmed bug discovered during implementation or review should normally get a regression test.

Test the dangerous behavior, not only the function.

Prefer:

- "paid reschedule does not increase duration without additional payment"

over:

- "reschedule returns 200"

Prefer:

- "repricing an unpaid booking retires an existing cheaper checkout attempt"

over:

- "payment initializes"

## Required pre-completion review

Before saying a meaningful coding task is complete:

1. Review the full diff.
2. Trace changed workflows end to end.
3. Identify state transitions and dependent records.
4. Look specifically for authorization, payment, concurrency, stale-state, idempotency, webhook, and partial-failure bugs.
5. Add regression tests for discovered bugs and risky edge cases.
6. Run formatting.
7. Compile with warnings treated as errors.
8. Run relevant tests, preferably the full suite for cross-cutting changes.
9. Review new dependencies and security advisories.
10. Report any remaining risks explicitly.

Do not assume green tests prove behavioral correctness. Actively search for valid inputs or request sequences that violate business invariants even when each individual function succeeds.

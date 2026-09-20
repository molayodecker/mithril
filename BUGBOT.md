# Mithril PR Review Standards

Review behavioral correctness, not only syntax, style, and test status.

Pay special attention to:

- payments and stale payment references
- booking state transitions
- authorization and ownership
- race conditions
- idempotency
- webhooks and callbacks
- stale dependent records
- partial transaction failures
- external integration round trips
- new dependencies
- missing regression tests

For payments, bookings, dispatch, authentication, refunds, rescheduling, and WhatsApp/webhook changes, trace the complete workflow.

Actively look for a sequence of individually valid requests that produces an invalid business state.

Flag cases where:

- paid service can change without corresponding payment
- an old payment reference remains valid after repricing
- the same callback can cause an action twice
- one user can manipulate another user's resource
- concurrent requests can assign, reserve, refund, or charge twice
- a successful write leaves dependent records stale
- outbound integration works but its inbound callback path is incomplete
- a failure halfway through leaves inconsistent state
- a client-supplied value overrides a server-owned invariant

Every confirmed bug should normally get a regression test that reproduces the dangerous behavior.

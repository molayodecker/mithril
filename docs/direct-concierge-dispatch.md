# Direct Concierge Dispatch

This phase turns Instaclean Direct into a concierge/dispatch surface in addition to self-service booking.

## Customer workflows

- **Urgent help**: request a househelp, nanny, cleaner, elder caregiver, cook, driver, or gardener for a specific time and duration.
- **Replacement request**: request backup for an existing owned booking. Only one active replacement request may exist per booking.
- Urgent help is explicitly a **non-medical household-services** workflow. Direct must not present it as emergency medical response.

## Operations workflows

- Search existing Instaclean customers by name, email, or phone.
- Create a booking on behalf of a customer using the canonical Direct booking pipeline.
- Record the booking source (`admin`, `phone`, or `whatsapp`), the staff user who created it, and explicit customer consent.
- View the dispatch queue ordered by open status and urgency.
- Assign a vetted worker to a request.
- For caregiver/household roles, assignment requires the worker to have opted into placements, be available, and include the requested role in `desired_roles`.
- Advance requests through `submitted`, `triaging`, `matching`, `assigned`, `resolved`, or `cancelled`.

## API

Customer:

```text
GET  /direct/service-requests
POST /direct/urgent-help
POST /direct/bookings/:id/replacement-request
```

Admin and reviewer (`GET /auth/me` reports `"admin"` and/or `"reviewer"`):

```text
GET  /direct/admin/customers?q=...
POST /direct/admin/bookings
GET  /direct/admin/service-requests
POST /direct/admin/service-requests/:id/assign
POST /direct/admin/service-requests/:id/status
```

Grant those roles on an existing user. Point Mix at the intended database (`DATABASE_BACKEND=fly` and `FLY_DATABASE_URL` for production):

```bash
mix mithril.staff.grant --phone +233… --role reviewer
# or
mix mithril.staff.grant --email you@tryinstaclean.com --role admin
```

## Database rollout

Apply Direct schema phases in order:

```bash
TARGET_DATABASE_URL='...' CONFIRM_DIRECT_SCHEMA=YES ./scripts/apply_direct_schema.sh
```

The runner applies every `priv/repo/sql/direct/*.sql` file in lexical order.

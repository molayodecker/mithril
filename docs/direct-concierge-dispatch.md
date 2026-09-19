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
- Choose whether to send customer and professional notifications after create or assignment. Default is on. Delivery is fail-open: the booking or assignment is kept if notify fails. When `SEND_NOTIFICATION_URL` is configured, Instaclean's `send-notification` edge function is used (email, SMS, WhatsApp). Otherwise Twilio SMS uses the same credentials as phone OTP.
- Visit reminders for concierge bookings run in Mithril/Oban, not Supabase `pg_cron`. An hourly sweep enqueues unique jobs for ~48h, ~24h, and morning-of (~08:00 Africa/Accra) customer reminders, plus a ~24h professional reminder. Stamps on `public.bookings` keep the legacy Instaclean cron from sending the same stage twice. Unpaid concierge visits are included.
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
That includes Oban job tables (`20260912000000_oban_jobs.sql`). After applying, deploy Mithril so the hourly reminder sweep can run. Fly must keep at least one Machine up (`min_machines_running = 1`) or the cron will not fire.

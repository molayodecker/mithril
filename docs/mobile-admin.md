# Mobile admin (Instaclean Direct)

The Expo app `instaclean-direct-mobile` talks to the same Mithril host as the Direct web app.

## Auth

| Method | Path |
|--------|------|
| Login | `POST /auth/login` |
| OTP | `POST /auth/otp`, `POST /auth/otp/verify` |
| Session | `GET /auth/me`, `POST /auth/refresh`, `POST /auth/logout` |

Staff must have `admin` or `reviewer` on `/auth/me`. Several ops routes require **admin** only (see below).

## Admin routes used by mobile

| Screen | Method | Path | Role |
|--------|--------|------|------|
| Bookings | GET | `/direct/admin/bookings` | staff |
| Live jobs | GET | `/direct/admin/live-jobs` | staff |
| Service requests | GET | `/direct/admin/service-requests` | staff |
| WhatsApp inbox | GET | `/direct/admin/whatsapp/threads` | staff |
| Dispatch map | GET | `/direct/admin/dispatch-map` | admin |
| Cleaners roster | GET | `/direct/admin/cleaners` | admin |
| Cleaner applications | GET | `/direct/admin/cleaner-applications` | admin |
| App update policy | GET, POST | `/direct/admin/app-update-policy` | admin |
| Services & pricing | GET | `/direct/admin/services`, `/direct/admin/services/:id` | staff |
| Services & pricing (save) | POST | `/direct/admin/services/:id` | admin |
| Promo codes | GET | `/direct/admin/promotion-codes` | staff |
| Reports | GET | `/direct/admin/reports/summary?days=7\|30\|90` | staff |
| Service areas | GET | `/direct/admin/service-areas` | staff |
| Payouts | GET | `/direct/admin/payouts?status=` | staff |
| Reviews | GET | `/direct/admin/reviews?filter=` | staff |
| Team | GET | `/direct/admin/team` | admin |
| Customers | GET | `/direct/admin/customers?q=` | admin |
| Customer trust | GET | `/direct/admin/customer-trust` | admin |
| Cleaner health | GET | `/direct/admin/cleaner-health` | admin |
| Placements | GET | `/direct/admin/placements` | admin |
| Concierge | GET | `/direct/admin/service-requests` | staff |

Configure the app with `EXPO_PUBLIC_MITHRIL_API_URL` (e.g. `https://dev.tryinstaclean.com`).

Grant admin:

```bash
mix mithril.staff.grant --email you@tryinstaclean.com --role admin
```

OpenAPI: `/openapi.json` on the API host.

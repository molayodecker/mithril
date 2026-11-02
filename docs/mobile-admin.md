# Mobile admin (Instaclean Direct)

The Expo app `instaclean-direct-mobile` talks to the same Mithril host as the Direct web app.

**Product copy:** the mobile app says **workers** (routes `/workers`, `/worker-health`). Mithril API paths still use `cleaner-*` and `cleaners` where the OpenAPI spec does.

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
| Workers roster | GET | `/direct/admin/cleaners` | admin |
| Worker applications | GET | `/direct/admin/cleaner-applications` | admin |
| Worker application drafts | GET | `/direct/admin/cleaner-application-drafts` | admin |
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
| Worker health | GET | `/direct/admin/cleaner-health` | admin |
| Contracts (month desk) | GET | `/direct/admin/contracts?month=` | admin |
| Placements | GET | `/direct/admin/placements` | admin |
| Concierge | GET | `/direct/admin/service-requests` | staff |
| Notifications history | GET | `/direct/admin/notifications?page=&limit=` | admin |

### Detail & mutations (mobile)

| Screen | Method | Path | Role |
|--------|--------|------|------|
| Assisted booking | POST | `/direct/admin/bookings` | admin |
| Booking detail | GET | `/direct/admin/bookings/:id` | staff |
| Assign worker | POST | `/direct/admin/bookings/:id/assign` | admin |
| Booking status | POST | `/direct/admin/bookings/:id/status` | admin |
| Cancel booking | POST | `/direct/admin/bookings/:id/cancel` | admin |
| Reschedule | POST | `/direct/admin/bookings/:id/reschedule` | admin |
| Notify worker | POST | `/direct/admin/bookings/:id/notify-cleaner` | admin |
| Send receipt | POST | `/direct/admin/bookings/:id/send-receipt` | admin |
| Reset hold | POST | `/direct/admin/bookings/:id/reset-hold` | admin |
| Cash payout | POST | `/direct/admin/bookings/:id/cash-payout` | admin |
| Job invoice | GET, PUT | `/direct/admin/bookings/:id/invoice` | admin |
| Send invoice | POST | `/direct/admin/bookings/:id/invoice/send` | admin |
| Booking workers (assign picker) | GET | `/direct/booking-cleaners?serviceId=` | admin |
| Service request detail | assign/status below | | staff |
| Assign SR | POST | `/direct/admin/service-requests/:id/assign` | admin |
| SR status | POST | `/direct/admin/service-requests/:id/status` | admin |
| WhatsApp thread | GET | `/direct/admin/whatsapp/messages?phone=` | staff |
| WhatsApp send | POST | `/direct/admin/whatsapp/send` | staff |
| WhatsApp SMS | POST | `/direct/admin/whatsapp/sms` | staff |
| Placement match | POST | `/direct/admin/placements/:id/matches` | admin |
| Candidates | GET | `/direct/admin/candidates` | admin |
| Worker application | GET | `/direct/admin/cleaner-applications/:id` | admin |
| Approve application | POST | `/direct/admin/cleaner-applications/:id/approve` | admin |
| Application draft | GET | `/direct/admin/cleaner-application-drafts/:id` | admin |
| Contract detail | GET | `/direct/admin/contracts/:id?month=` | admin |
| Customer trust detail | GET | `/direct/admin/customer-trust/:customerId` | admin |
| Trust note / action | POST | `.../notes`, `.../actions` | admin |
| Worker health case | GET | `/direct/admin/cleaner-health/:caseId` | admin |
| Health action | POST | `.../actions` | admin |
| Team grant / revoke | POST | `/direct/admin/team/grant`, `.../revoke` | admin |
| Merge accounts | POST | `/direct/admin/accounts/merge` | admin |
| Send notification | POST | `/direct/admin/notifications` | admin |
| Notification targets | GET | `/direct/admin/notification-targets?q=` | admin |
| Broadcast | POST | `/direct/admin/notification-broadcast` | admin |
| Worker wallet | GET | `/direct/admin/cleaners/:id/wallet` | admin |
| Wallet credit | POST | `/direct/admin/cleaners/:id/wallet-credit` | admin |
| Billing invoices | GET | `/direct/admin/billing/invoices?page=` | admin |
| Payment advice | GET | `/direct/admin/billing/payment-advices?page=` | admin |
| Payment requests | GET, POST | `/direct/admin/billing/payment-requests` | admin |
| Payment request actions | POST | `.../payment-requests/:id/pause\|resume\|retry\|reminders` | admin |
| Worker loans | GET | `/direct/admin/worker-loan-requests?status=` | admin |
| Review loan | POST | `/direct/admin/worker-loan-requests/:id/review` | admin |

### Web admin not yet in mobile (backlog)

| Area | Notes |
|------|--------|
| Contract mutations | Create contract, payday, advances, letters (mobile is list + read-only detail) |
| Billing invoice/advice editors | Web PUT save flows; mobile lists read-only |
| Placements WhatsApp desk | Web-only placement messaging UI |
| Application draft CRUD | Mobile read-only draft detail |
| Team access permissions | Web `team/access` fine-grained permissions |
| Broadcast preview | Web preview endpoint before send |
| Rich job invoice editor | Web line-item editor; mobile save/send simplified |

Configure the app with `EXPO_PUBLIC_MITHRIL_API_URL`:

| Context | URL |
|---------|-----|
| Local Expo / EAS preview & development | `https://instaclean-mithril-staging.fly.dev` |
| EAS production | `https://api.tryinstaclean.com` |

Optional `EXPO_PUBLIC_MITHRIL_ENV` (`staging` \| `production` \| `local`) is shown in mobile Settings. If `EXPO_PUBLIC_MITHRIL_API_URL` is omitted at build time, the client defaults to **staging** (never production).

Grant admin:

```bash
mix mithril.staff.grant --email you@tryinstaclean.com --role admin
```

OpenAPI: `/openapi.json` on the API host.

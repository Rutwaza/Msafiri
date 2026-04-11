# B) Proposed Target Architecture (Frontend + Backend)

## Frontend (Flutter)
- `lib/features/auth/*`
  - Traffic-only profile model (`traffic_users`).
  - Auth orchestration + onboarding completion.
  - Role/state read model used by router and UI guards.
- `lib/presentation/pages/*`
  - Auth pages: identity proof only.
  - Onboarding page: final traffic profile completion.
  - Traffic page: rider operations only.
  - Admin page: visible only for `agency_staff|agency_admin|super_admin`.
- Router enforcement (single source of truth)
  - Unauthenticated -> login/register.
  - Authenticated but onboarding incomplete -> onboarding.
  - Admin route requires allowed role.

## Backend (Firebase)
- Firestore
  - `traffic_users/{uid}`: auth profile + role + status + onboarding state.
  - Traffic domain collections: agencies, routes, buses, cards, bookings, ledger, admin_events.
- RTDB
  - `telemetry/{agencyId}/{busId}/latest` and rolling points for devices.
  - Device writes restricted by device token/custom claim path.
- Cloud Functions (callable + scheduled)
  - Booking flow: `bookSeat`, `tapCard`, `releaseSeat`, expiry jobs.
  - Role checks centralized in shared guard util.
  - Finance/report jobs by agency and global super-admin summary.
- Security
  - Firestore rules with role + scope checks (`agencyId`, ownership, super-admin override).
  - RTDB rules scoped by authenticated device/user role and ownership.

## Delivery Plan
1. Auth + onboarding model (implemented now).
2. Firestore final schema and indexes.
3. RTDB telemetry schema + validation contract.
4. Functions scaffolding and transactional booking/tap flow.
5. Hardened Firestore/RTDB rules.
6. Admin/staff role lifecycle flow.
7. Device (ESP32) contract + validation.
8. End-to-end test scripts and production checklist.
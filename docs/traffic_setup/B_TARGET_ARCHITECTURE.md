# B) Proposed Target Architecture (Frontend + Backend)

Date: 2026-04-09

## Frontend target (Flutter)
- `lib/features/auth/`
  - domain: traffic user profile model (`role`, `status`, `onboarding`)
  - data: centralized auth/profile service
  - providers: Riverpod auth/profile streams
- `lib/presentation/pages/auth/`
  - sign-in/register only
- `lib/presentation/pages/onboarding/`
  - required post-auth onboarding completion
- `GoRouter` guard flow:
  - unauthenticated -> `/login`
  - authenticated + onboarding incomplete -> `/onboarding`
  - authenticated + onboarding complete -> `/traffic-management`
  - admin route only for `agency_staff|agency_admin|super_admin`

## Backend target (Firebase)
- Firestore:
  - `traffic_users/{uid}` authoritative identity/profile/access state
  - traffic domain collections (`agencies`, `routes`, `buses`, `cards`, `bookings`, `transactions`, `admin_events`, etc.)
- Realtime Database:
  - telemetry-only tree for live device updates (`devices/{busId}/...`)
- Cloud Functions:
  - callable/domain services (`bookSeat`, `tapCard`, `releaseSeat`, `expireBookings`, role checks, finance reports)
  - scheduled jobs for expiry/reconciliation
- Security:
  - Firestore + RTDB strict role and agency scoping
  - server-side validation in Functions for all sensitive mutations

## Risky decision and recommendation
1. Option A: Keep using legacy `users` as primary profile source.
2. Option B (Recommended): Use `traffic_users` as authoritative now, keep legacy `users` compatibility reads temporarily.
3. Option C: Hard-cut migration to only `traffic_users` immediately.

Recommendation: Option B. It reduces production risk while letting us migrate remaining legacy reads in controlled steps.

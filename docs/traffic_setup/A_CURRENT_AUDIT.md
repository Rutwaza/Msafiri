# A) Current Project Audit - spotlight_traffic_app

Date: 2026-04-09

## What exists now
- Standalone Flutter app folder with independent Android/iOS/Web/Desktop targets.
- Android package is set to `com.spotlight.traffic`.
- Firebase Android config exists at `android/app/google-services.json`.
- Firebase options in app point to project `spotlight-traffic-prod`.
- App already uses `firebase_auth`, `cloud_firestore`, `firebase_database`, `cloud_functions`.
- UI pages exist for login/register, traffic map/booking flow, and admin dashboard.

## Gaps found for production traffic-only architecture
- No dedicated traffic domain user model before this step (role/onboarding/status were mixed or implicit).
- No dedicated onboarding route gate for authenticated users.
- Auth logic duplicated in multiple pages.
- No backend infrastructure files inside this standalone app yet:
  - no local `functions/` for this app
  - no `firestore.rules` scoped here
  - no `database.rules.json` scoped here
  - no `firestore.indexes.json` scoped here
- UI still had some social-era wording.

## Current risk notes
- Some code still references legacy collections (`users`) in older screens. We are introducing `traffic_users` as authoritative profile source first, then we will fully migrate remaining reads/writes in later steps.
- `flutter analyze` currently reports info-level warnings across older files (async context + deprecated opacity usage), but no hard compile errors from Step 1.

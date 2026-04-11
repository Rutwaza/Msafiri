# A) Current Project Audit - spotlight_traffic_app

Date: 2026-04-09

## What Exists
- Standalone Flutter app root with separate Android package.
- Android package/namespace configured as `com.spotlight.traffic`.
- Firebase Android config points to `spotlight-traffic-prod`.
- `google-services.json` exists at `android/app/google-services.json`.
- Current screens:
  - Auth: login/register with email, Google, phone.
  - Traffic screen with live RTDB/Firestore usage and Cloud Functions calls.
  - Admin dashboard screen with agency/super-admin operations.

## Gaps Found (Production Readiness)
- No dedicated backend folder in this app for:
  - Firestore rules
  - RTDB rules
  - Functions source
  - indexes/ops config
- Auth/profile model was mixed with generic legacy `users` shape and social leftovers.
- No dedicated traffic onboarding gate before entering core traffic flow.
- Role guard in UI/router was incomplete (admin route visible before role model check).
- No explicit traffic domain docs for schema, telemetry contract, and deployment checklist.

## Existing Risk Flags
- Traffic screen hardcodes RTDB URL currently (`bussinessfinder-327f5-default-rtdb`).
- App currently consumes collections/functions without local, versioned contract docs.
- Some auth copy/assets still use generic Spotlight wording from prior mixed app context.
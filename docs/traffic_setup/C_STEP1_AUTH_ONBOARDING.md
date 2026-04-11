# C) Step 1 Implementation - Auth + Onboarding Model (Traffic-only)

Date: 2026-04-09

## What we're doing
- Introduce a traffic-only user profile model in Firestore (`traffic_users`).
- Centralize auth/profile synchronization logic.
- Force onboarding completion after first login/registration.
- Gate admin dashboard access by role.
- Remove obvious social copy from auth screens.

## Exact files changed
- `lib/features/auth/domain/traffic_user_profile.dart`
- `lib/features/auth/data/traffic_auth_service.dart`
- `lib/features/auth/providers/auth_providers.dart`
- `lib/presentation/pages/onboarding/onboarding_page.dart`
- `lib/core/constants/app_constants.dart`
- `lib/main.dart`
- `lib/presentation/pages/auth/login_page.dart`
- `lib/presentation/pages/auth/register_page.dart`

## Exact commands to run
```powershell
cd c:\Users\Nexon\Desktop\PROJECTS\BussFinder\bussinessfinder\spotlight_traffic_app
flutter pub get
dart format lib
flutter analyze
flutter run
```

## How to verify it worked
1. Auth gate:
- Sign out, relaunch app -> should land on `/login`.

2. Profile creation:
- Register/sign in with a new account.
- In Firestore, confirm `traffic_users/{uid}` exists with fields:
  - `role`, `status`, `onboarding.completed`, `lastLoginAt`.

3. Onboarding gate:
- New user should be redirected to `/onboarding` before traffic map.
- Complete onboarding form -> redirected to `/traffic-management`.
- `traffic_users/{uid}.onboarding.completed` becomes `true`.

4. Role gate:
- Non-admin profile tries to open `/admin-dashboard` -> redirected to `/traffic-management`.
- Agency/super roles from `agency_members` or super-admin email can access admin dashboard.

## Notes
- This step intentionally introduces `traffic_users` as authoritative profile state while preserving compatibility with existing app flows.
- Next steps will finalize Firestore/RTDB schemas, functions, and hardened rules around this model.

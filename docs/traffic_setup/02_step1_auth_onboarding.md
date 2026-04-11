# C) Step 1 - Auth + User Onboarding (Traffic Only)

## What We Are Doing
- Introduce a dedicated traffic profile model in Firestore: `traffic_users/{uid}`.
- Ensure every successful sign-in has a traffic profile with role/status.
- Enforce onboarding completion before entering traffic management.
- Restrict admin access in router/UI based on role.

## Exact Files Changed
- `lib/features/auth/domain/traffic_user_profile.dart`
- `lib/features/auth/data/traffic_auth_service.dart`
- `lib/features/auth/providers/auth_providers.dart`
- `lib/presentation/pages/onboarding/onboarding_page.dart`
- `lib/core/constants/app_constants.dart`
- `lib/main.dart`
- `lib/presentation/pages/auth/login_page.dart`
- `lib/presentation/pages/auth/register_page.dart`
- `lib/presentation/pages/traffic/traffic_management_page.dart`

## Exact Commands To Run
```powershell
cd c:\Users\Nexon\Desktop\PROJECTS\BussFinder\bussinessfinder\spotlight_traffic_app
flutter pub get
flutter analyze
flutter run -d android
```

## How To Verify It Worked
1. Create a new account from Register page.
- Expected: user is routed to `/onboarding` first, not directly to traffic page.

2. Complete onboarding form and submit.
- Expected: user lands on `/traffic-management`.
- Firestore expected document: `traffic_users/{uid}` with:
  - `role`, `status`, `onboarding.completed=true`, `lastLoginAt`.

3. Sign out and sign in again.
- Expected: no onboarding loop for completed profile.

4. Try opening admin route as rider.
- Expected: router redirects to `/traffic-management`.

5. Sign in as agency staff/admin/super-admin user.
- Expected: admin icon visible in traffic page and admin route allowed.

## Risk Decision (Made)
- Kept current operational collections/screens intact to avoid breaking current traffic workflows.
- Introduced `traffic_users` as the new authoritative auth/onboarding model for all new role/state enforcement.
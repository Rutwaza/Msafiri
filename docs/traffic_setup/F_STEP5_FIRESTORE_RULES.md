# F) Step 5 - Firestore Security Rules (Hardened)

Date: 2026-04-10

## What we changed
- Replaced deny-all Firestore rules with hardened, traffic-domain rules.
- Added role helpers (`super_admin`, `agency_staff`, `agency_admin`) based on `traffic_users`.
- Scoped write access by agency for traffic collections.
- Preserved temporary compatibility for legacy `users` collection reads/writes by self only.

## Exact files changed
- `firestore.rules`
- `firebase.json`
- `.firebaserc`

## Exact commands to run
```powershell
cd c:\Users\Nexon\Desktop\PROJECTS\BussFinder\bussinessfinder\spotlight_traffic_app
firebase deploy --only firestore:rules,firestore:indexes
```

## How to verify
1. Sign up/login should now create/update `traffic_users/{uid}` without permission-denied.
2. Rider can read own profile/cards/bookings but cannot write admin collections directly.
3. Agency staff/admin can manage agency-scoped routes/buses/cards/bookings.
4. Super admin can manage all.

## Temporary compatibility note
- `match /users/{uid}` currently allows:
  - read for signed-in users
  - create/update only for owner (`uid == request.auth.uid`)
- This is to avoid breaking existing screens during migration.
- We should remove this compatibility block after all app reads are moved to `traffic_users`.

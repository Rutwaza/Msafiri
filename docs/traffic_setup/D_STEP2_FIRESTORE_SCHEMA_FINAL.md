# D) Step 2 - Firestore Schema Finalization (Traffic Domain)

Date: 2026-04-09

## What we're doing
- Lock a traffic-only Firestore contract for production.
- Standardize collection names and enums in code.
- Add required composite indexes for existing app queries.

## Risky design decision (paused + recommended)
1. Keep writing traffic identities into legacy `users` only.
2. Write to `traffic_users` as authoritative, keep temporary legacy compatibility reads (Recommended).
3. Hard-delete all legacy `users` dependencies now.

Recommendation: Option 2. It protects production rollout while we complete migration safely in later steps.

## Exact files changed
- `lib/core/constants/firestore_collections.dart`
- `lib/features/auth/data/traffic_auth_service.dart`
- `docs/traffic_setup/schema/firestore_schema_v1.json`
- `firestore.indexes.json`

## Finalized collection set
- `traffic_users`
- `agency_members`
- `agencies`
- `routes`
- `buses`
- `cards`
- `bookings`
- `card_transactions`
- `admin_events`
- `direction_requests`
- `agency_applications`
- `agency_password_reset_requests`

## Exact commands to run
```powershell
cd c:\Users\Nexon\Desktop\PROJECTS\BussFinder\bussinessfinder\spotlight_traffic_app
flutter pub get
dart format lib\core\constants\firestore_collections.dart lib\features\auth\data\traffic_auth_service.dart
flutter analyze
```

If Firebase CLI is configured for this app root:
```powershell
firebase firestore:indexes
firebase deploy --only firestore:indexes
```

## How to verify it worked
1. Schema contract present:
- Open `docs/traffic_setup/schema/firestore_schema_v1.json`.
- Confirm required fields and enums for all traffic collections.

2. App-side constants:
- Confirm auth service references `FsCollections.trafficUsers` and `FsCollections.agencyMembers`.

3. Indexes:
- Open `firestore.indexes.json` and confirm indexes exist for:
  - `bookings (agencyId + createdAt)`
  - `admin_events (agencyId + createdAt)`
  - `card_transactions (userId + createdAt)`
  - `direction_requests (status + createdAt)`
  - `routes (global + origin)`

4. Analyzer:
- `flutter analyze` should complete with only info-level warnings from existing UI files.

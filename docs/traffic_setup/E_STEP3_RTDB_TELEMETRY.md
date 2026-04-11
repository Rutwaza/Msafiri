# E) Step 3 - Realtime DB Structure (Live Device Telemetry)

Date: 2026-04-10

## What we're changing
- Keep your existing RTDB payload shape fully supported (`devices/{busId}/-T*`).
- Add compatibility for normalized shape (`meta`, `latest`, `history`) for future scale.
- Switch app telemetry client to the new RTDB URL:
  - `https://spotlight-traffic-prod-default-rtdb.firebaseio.com`

## Risky decision (with recommendation)
1. Keep only legacy `-T*` nodes forever.
2. Break to normalized shape immediately (`meta/latest/history`) and rewrite firmware now.
3. Support both legacy and normalized during migration (Recommended).

Recommendation: Option 3. No downtime, no immediate hardware rewrite, safe migration.

## Exact files changed
- `lib/core/constants/realtime_db_contract.dart`
- `lib/presentation/pages/traffic/traffic_management_page.dart`
- `docs/traffic_setup/schema/rtdb_telemetry_contract_v1.json`

## Firmware note (hardware.ino)
Update only RTDB URL target to the new project:
```cpp
#define DATABASE_URL "https://spotlight-traffic-prod-default-rtdb.firebaseio.com/"
```
Keep existing payload writes under `/devices/{deviceId}/-T*` unchanged for now.

## Exact commands to run
```powershell
cd c:\Users\Nexon\Desktop\PROJECTS\BussFinder\bussinessfinder\spotlight_traffic_app
dart format lib\core\constants\realtime_db_contract.dart lib\presentation\pages\traffic\traffic_management_page.dart
flutter analyze
flutter run
```

## How to verify it worked
1. Confirm app points to new RTDB URL:
- Open `lib/core/constants/realtime_db_contract.dart`.

2. Validate legacy telemetry still renders:
- Push your existing firmware payload (with `-T1`, `-T2` etc.) to new DB.
- Open traffic map/list in app and confirm buses appear and update.

3. Validate normalized compatibility (optional):
- Add one test device with:
  - `devices/{id}/meta`
  - `devices/{id}/latest`
- Confirm app reads that device without requiring `-T*` entries.

4. Data continuity check:
- Existing fields (`agencyName`, `plateNumber`, `sits`) continue to show correctly.

## Contract source
- `docs/traffic_setup/schema/rtdb_telemetry_contract_v1.json`

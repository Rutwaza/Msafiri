# Route Direction + Seat Window Model (v2)

## 1) Direction Pair Model
- Super admin defines one corridor with ordered stops, for example:
  - `Remera -> Rwamagana -> Kayonza -> Kibungo -> Nyakarambi`
- System stores two direction docs in `route_directions`:
  - `forward`: exact order above
  - `reverse`: reversed order

Each `route_directions/{directionId}` contains:
- `pairId`
- `corridorName`
- `directionLabel` (`forward` or `reverse`)
- `stopNames` (ordered array)
- `segments` (all valid origin->destination pairs in this direction)
- `reverseDirectionId`

## 2) Bus Assignment
- Super admin assigns one direction to each bus using `assignBusDirectionV2`.
- Stored in `bus_direction_assignments/{busId}` with:
  - `directionId`
  - `reverseDirectionId`
  - `currentStopIndex`
  - `stopNames`

## 3) Booked -> Paid -> Free Seat Logic
For each paid seat, store lock in:
- `seat_locks/{busId}/seats/{seatNo}`

Recommended fields:
- `directionId`
- `originStopIndex`
- `destinationStopIndex`
- `paidAtMs`
- `releaseAtMs` (time-based fallback, e.g., +10 minutes)

Seat is considered reusable when ANY is true:
1. Request is in opposite direction (`request.directionId != lock.directionId`)
2. Request origin is at/after lock destination (`request.originStopIndex >= lock.destinationStopIndex`)
3. Time lock expired (`nowMs >= releaseAtMs`)

Otherwise seat remains occupied for the segment.

## 4) Your Example Mapping
For route:
- `Remera(0) -> Rwamagana(1) -> Kayonza(2) -> Kibungo(3) -> Nyakarambi(4)`

If user paid seat for:
- `Remera(0) -> Kayonza(2)`

Then:
- Blocked for same-direction requests that overlap `[0,2)`.
- Free for same-direction requests starting at Kayonza (`origin >= 2`), e.g.:
  - `Kayonza -> Kibungo`
  - `Kayonza -> Nyakarambi`
- Not free for reverse-direction segment until reversed trip context is used.

When bus starts reverse run, use reverse direction doc and apply same rules symmetrically.

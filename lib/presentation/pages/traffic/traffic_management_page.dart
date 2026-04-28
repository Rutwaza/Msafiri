import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart' show FirebaseDatabase, DatabaseEvent;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:spotlight_traffic_app/core/constants/app_constants.dart';
import 'package:spotlight_traffic_app/core/constants/realtime_db_contract.dart';
import 'package:spotlight_traffic_app/core/widgets/spotlight_loader.dart';
import 'package:spotlight_traffic_app/core/widgets/spotlight_toast.dart';
import 'package:spotlight_traffic_app/features/auth/data/traffic_auth_service.dart';
import 'package:spotlight_traffic_app/features/auth/domain/traffic_user_profile.dart';

class TrafficManagementPage extends StatefulWidget {
  const TrafficManagementPage({
    super.key,
    this.initialBusId,
    this.embeddedInShell = false,
  });
  final String? initialBusId;
  final bool embeddedInShell;

  @override
  State<TrafficManagementPage> createState() => _TrafficManagementPageState();
}

enum _Filter { agency, nearest, eta }

enum _BookState { idle, selectingRoute, booking, booked, paid, expired, failed }

enum _ProfileAction { profile, logout }

class _TrafficManagementPageState extends State<TrafficManagementPage> {
  static const _center = LatLng(-1.9441, 30.0619);

  final _rtdb = FirebaseDatabase.instanceFor(
    app: FirebaseDatabase.instance.app,
    databaseURL: RtdbContract.dbUrl,
  );
  final _fs = FirebaseFirestore.instance;
  final _fx = FirebaseFunctions.instanceFor(region: 'us-central1');
  final _authService = TrafficAuthService();
  final _icons = <String, BitmapDescriptor>{};

  GoogleMapController? _map;
  StreamSubscription<DatabaseEvent>? _telemetrySub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _metaSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _routesSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _assignmentsSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _myBookingsSub;
  final Map<String, StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>
      _seatLockBusSubs = {};
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _bookingSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _myCardsSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _notificationsSub;
  Timer? _internetTimer;
  Timer? _internetHideTimer;
  Timer? _markerRebuildTimer;
  Timer? _bookedBusPulseTimer;

  final _meta = <String, _Meta>{};
  final _telemetry = <String, _Live>{};
  final _assignments = <String, _DirectionAssignment>{};
  final _seatLocks = <_SeatLock>[];
  List<_Route> _routes = [];
  Set<Marker> _markers = {};

  LatLng _mapCenter = _center;
  LatLng? _me;
  String? _routeId;
  int? _originStopIndex;
  int? _destinationStopIndex;
  double _zoom = 13;
  bool _loading = true;
  bool _mapDark = false;
  MapType _mapType = MapType.hybrid;
  TrafficUserProfile? _profile;
  int _token = 0;
  _BookState _bookState = _BookState.selectingRoute;
  String? _bookErr;
  _BookSession? _session;
  final _myCards = <_CardInfo>[];
  String? _selectedCardId;
  bool _didInitialBusFocus = false;
  bool _internetAvailable = true;
  bool _showInternetBadge = false;
  int _lastInternetStatusCode = 204;
  bool _actionLoading = false;
  String _actionLoadingText = 'Processing request...';
  String _historySearchQuery = '';
  String _bookingsSearchQuery = '';
  final Set<String> _nearbyBusNotified = <String>{};
  final Set<String> _bookedBusIds = <String>{};
  final Set<String> _pendingBookedBusIds = <String>{};
  final Set<String> _knownNotificationIds = <String>{};
  final Map<String, int> _pendingBookedFareByCard = <String, int>{};
  final Map<String, int> _pendingBookedFareByBusAndCard = <String, int>{};
  bool _notificationsPrimed = false;
  bool _autoClearChecked = false;
  bool _bookedBusPulseOn = false;
  bool get _mapsPaused => AppConstants.pauseGoogleMaps;

  Future<T> _runWithActionLoader<T>(
    String message,
    Future<T> Function() action,
  ) async {
    if (mounted) {
      setState(() {
        _actionLoading = true;
        _actionLoadingText = message;
      });
    }
    try {
      return await action();
    } finally {
      if (mounted) {
        setState(() => _actionLoading = false);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _locate();
    _listenTelemetry();
    _listenMeta();
    _listenRoutes();
    _listenAssignments();
    _listenMyBookedBuses();
    _listenMyCards();
    _listenNotificationPopups();
    unawaited(_applyAutoClearPolicies());
    _startInternetMonitor();
    _startBookedBusPulse();
  }

  @override
  void dispose() {
    _telemetrySub?.cancel();
    _metaSub?.cancel();
    _routesSub?.cancel();
    _assignmentsSub?.cancel();
    _myBookingsSub?.cancel();
    for (final sub in _seatLockBusSubs.values) {
      sub.cancel();
    }
    _seatLockBusSubs.clear();
    _bookingSub?.cancel();
    _myCardsSub?.cancel();
    _notificationsSub?.cancel();
    _internetTimer?.cancel();
    _internetHideTimer?.cancel();
    _markerRebuildTimer?.cancel();
    _bookedBusPulseTimer?.cancel();
    _map?.dispose();
    super.dispose();
  }

  void _startBookedBusPulse() {
    _bookedBusPulseTimer?.cancel();
    _bookedBusPulseTimer = Timer.periodic(const Duration(milliseconds: 650), (_) {
      if (!mounted) return;
      if (_bookState != _BookState.booked || _session == null) return;
      _bookedBusPulseOn = !_bookedBusPulseOn;
      unawaited(_buildMarkers());
    });
  }

  void _scheduleMarkerRebuild({
    Duration delay = const Duration(milliseconds: 900),
  }) {
    _markerRebuildTimer?.cancel();
    _markerRebuildTimer = Timer(delay, () {
      if (!mounted) return;
      unawaited(_buildMarkers());
    });
  }

  void _startInternetMonitor() {
    unawaited(_checkInternet());
    _internetTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_checkInternet());
    });
  }

  Future<void> _checkInternet() async {
    int statusCode = 0;
    bool online = false;
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
      final req = await client.getUrl(
        Uri.parse('https://clients3.google.com/generate_204'),
      );
      req.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      final res = await req.close().timeout(const Duration(seconds: 5));
      statusCode = res.statusCode;
      online = statusCode >= 200 && statusCode < 500;
      await res.drain<void>();
    } catch (_) {
      statusCode = 0;
      online = false;
    } finally {
      client?.close(force: true);
    }

    if (!mounted) return;
    if (online == _internetAvailable && statusCode == _lastInternetStatusCode) {
      return;
    }

    final wasOffline = !_internetAvailable;
    setState(() {
      _internetAvailable = online;
      _lastInternetStatusCode = statusCode;
      if (!online) {
        _showInternetBadge = true;
      } else if (wasOffline) {
        _showInternetBadge = true;
      }
    });

    if (online && wasOffline) {
      _internetHideTimer?.cancel();
      _internetHideTimer = Timer(const Duration(seconds: 3), () {
        if (!mounted) return;
        setState(() => _showInternetBadge = false);
      });
    }
  }

  Widget _internetBadge() {
    if (!_showInternetBadge) return const SizedBox.shrink();
    final online = _internetAvailable;
    final bg = online ? const Color(0xCC14532D) : const Color(0xCC7F1D1D);
    final border = online ? const Color(0xFF22C55E) : const Color(0xFFEF4444);
    final icon = online ? Icons.wifi_rounded : Icons.wifi_off_rounded;
    final text = online
        ? 'Internet ON ($_lastInternetStatusCode)'
        : 'No Internet (${_lastInternetStatusCode == 0 ? 'ERR' : _lastInternetStatusCode})';
    return Positioned(
      top: 96,
      right: 12,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 16),
            const SizedBox(width: 6),
            Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _listenTelemetry() {
    _telemetrySub = _rtdb.ref(RtdbContract.devicesPath).onValue.listen((e) {
      final next = <String, _Live>{};
      if (e.snapshot.value is Map) {
        final root = e.snapshot.value as Map;
        root.forEach((k, v) {
          if (v is! Map) return;
          final m = Map<String, dynamic>.from(v);
          final meta = _extractMeta(m);
          final latest = _extractLatestTelemetryPoint(m);
          if (latest == null) return;
          final lat = _toDouble(latest['lat']);
          final lng = _toDouble(latest['lng']);
          if (lat == null || lng == null) return;
          next['$k'] = _Live(
            id: '$k',
            pos: LatLng(lat, lng),
            speed: _toDouble(latest['spd']),
            sits: _i(meta['sits']),
            agencyName: '${meta['agencyName'] ?? ''}'.trim(),
            plateNumber: '${meta['plateNumber'] ?? ''}'.trim(),
          );
        });
      }
      if (!mounted) return;
      setState(() {
        _telemetry
          ..clear()
          ..addAll(next);
        _loading = false;
      });
      _refreshSeatLockBusSubscriptions();
      _scheduleMarkerRebuild();
    }, onError: (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    });
  }

  void _cycleMapType() {
    setState(() {
      _mapType = switch (_mapType) {
        MapType.hybrid => MapType.normal,
        MapType.normal => MapType.satellite,
        _ => MapType.hybrid,
      };
    });
  }

  IconData _mapTypeIcon() {
    return switch (_mapType) {
      MapType.hybrid => Icons.layers_rounded,
      MapType.normal => Icons.map_rounded,
      MapType.satellite => Icons.satellite_alt_rounded,
      _ => Icons.layers_rounded,
    };
  }

  void _listenMeta() {
    _metaSub = _fs.collection('buses').snapshots().listen((s) {
      _meta.clear();
      for (final d in s.docs) {
        final m = d.data();
        _meta[d.id] = _Meta(
          id: d.id,
          routeId: '${m['routeId'] ?? ''}',
          routeIds: (m['routeIds'] as List<dynamic>? ?? const [])
              .map((e) => '$e')
              .where((e) => e.trim().isNotEmpty)
              .toList(),
          plate: '${m['plateNumber'] ?? ''}',
          agency: '${m['agencyName'] ?? ''}',
          seats: (m['availableSeats'] as num?)?.toInt(),
          active: m['active'] != false,
        );
      }
      _scheduleMarkerRebuild();
    });
  }

  void _listenRoutes() {
    _routesSub = _fs
        .collection('route_directions')
        .where('active', isEqualTo: true)
        .snapshots()
        .listen((s) {
      final r = s.docs.map((d) {
        final m = d.data();
        final stops = (m['stopNames'] as List<dynamic>? ?? const [])
            .map((e) => '$e')
            .where((e) => e.trim().isNotEmpty)
            .toList();
        return _Route(
          id: d.id,
          corridorName: '${m['corridorName'] ?? ''}',
          directionLabel: '${m['directionLabel'] ?? ''}',
          stopNames: stops,
          fare: (m['defaultFareRwf'] as num?)?.toInt() ?? 0,
          faresBySegment: _parseSegmentFares(
            m['faresBySegment'] as Map? ?? const {},
          ),
        );
      }).toList();
      if (!mounted) return;
      setState(() {
        _routes = r;
        if (_routeId != null && !_routes.any((e) => e.id == _routeId)) {
          _routeId = null;
        }
        _syncSegmentSelectionForRoute(_selectedRoute);
      });
      _scheduleMarkerRebuild();
    });
  }

  Map<String, int> _parseSegmentFares(Map raw) {
    final out = <String, int>{};
    raw.forEach((k, v) {
      if (v is num) {
        out['$k'] = v.toInt();
      } else if (v is Map && v['fareRwf'] is num) {
        out['$k'] = (v['fareRwf'] as num).toInt();
      }
    });
    return out;
  }

  void _listenAssignments() {
    _assignmentsSub = _fs
        .collection('bus_direction_assignments')
        .where('active', isEqualTo: true)
        .snapshots()
        .listen((s) {
      final next = <String, _DirectionAssignment>{};
      for (final d in s.docs) {
        final m = d.data();
        next[d.id] = _DirectionAssignment(
          busId: d.id,
          directionId: '${m['directionId'] ?? ''}',
          agencyId: '${m['agencyId'] ?? ''}',
          agencyName: '${m['agencyName'] ?? ''}',
        );
      }
      if (!mounted) return;
      setState(() {
        _assignments
          ..clear()
          ..addAll(next);
      });
      _refreshSeatLockBusSubscriptions();
      _scheduleMarkerRebuild();
    });
  }

  void _listenNotificationPopups() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    _notificationsSub = _fs
        .collection('user_notifications')
        .where('userId', isEqualTo: uid)
        .limit(120)
        .snapshots()
        .listen((s) {
      final freshUnread = <Map<String, dynamic>>[];
      for (final d in s.docs) {
        final m = d.data();
        final isUnread = m['read'] != true;
        if (!_knownNotificationIds.contains(d.id)) {
          _knownNotificationIds.add(d.id);
          if (_notificationsPrimed && isUnread) {
            freshUnread.add(m);
          }
        }
      }
      if (!_notificationsPrimed) {
        _notificationsPrimed = true;
        return;
      }
      for (final m in freshUnread) {
        if (!mounted) return;
        final title = '${m['title'] ?? 'Notification'}'.trim();
        final body = '${m['body'] ?? ''}'.trim();
        final type = '${m['type'] ?? ''}'.toLowerCase();
        final data = Map<String, dynamic>.from(m['data'] as Map? ?? const {});
        final dataSuccess = data['success'] == true;
        final explicitFailure = data['success'] == false;
        final greenTypes = <String>{
          'top_up',
          'ride_payment',
          'tap_result',
          'card_issued',
          'card_replaced',
        };
        final redTypes = <String>{
          'low_balance',
        };
        final isFailureText = title.toLowerCase().contains('failed') ||
            body.toLowerCase().contains('failed');
        final success = explicitFailure || isFailureText || redTypes.contains(type)
            ? false
            : (dataSuccess || greenTypes.contains(type));
        showSpotlightToast(
          context,
          body.isEmpty ? title : '$title: $body',
          success: success,
        );
      }
    }, onError: (_) {});
  }

  void _refreshSeatLockBusSubscriptions() {
    final targetBusIds = <String>{..._telemetry.keys, ..._assignments.keys};

    final toRemove = _seatLockBusSubs.keys
        .where((busId) => !targetBusIds.contains(busId))
        .toList();
    for (final busId in toRemove) {
      _seatLockBusSubs.remove(busId)?.cancel();
    }

    for (final busId in targetBusIds) {
      if (_seatLockBusSubs.containsKey(busId)) continue;
      final sub = _fs
          .collection('seat_locks')
          .doc(busId)
          .collection('seats')
          .snapshots()
          .listen(
        (s) {
          _mergeSeatLocksForBus(busId, s.docs);
        },
        onError: (_) {
          _mergeSeatLocksForBus(busId, const []);
        },
      );
      _seatLockBusSubs[busId] = sub;
    }
  }

  void _mergeSeatLocksForBus(
    String busId,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final nextForBus = <_SeatLock>[];
    for (final d in docs) {
      final m = d.data();
      final originStopIndex = (m['originStopIndex'] as num?)?.toInt() ?? -1;
      final destinationStopIndex =
          (m['destinationStopIndex'] as num?)?.toInt() ?? -1;
      final active = (m['status'] ?? 'booked') != 'released';
      nextForBus.add(
        _SeatLock(
          busId: busId,
          seatNo: int.tryParse(d.id) ?? 0,
          directionId: '${m['directionId'] ?? m['routeId'] ?? ''}'.trim(),
          originStopIndex: originStopIndex,
          destinationStopIndex: destinationStopIndex,
          active: active,
        ),
      );
    }

    if (!mounted) return;
    setState(() {
      _seatLocks.removeWhere((e) => e.busId == busId);
      _seatLocks.addAll(nextForBus);
    });
  }

  void _listenMyCards() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    _myCardsSub = _fs
        .collection('cards')
        .where('userId', isEqualTo: uid)
        .snapshots()
        .listen((s) {
      final cards = s.docs.where((d) {
        final m = d.data();
        return '${m['status'] ?? ''}' != 'lost_replaced';
      }).map((d) {
        final m = d.data();
        return _CardInfo(
          id: d.id,
          balance: (m['balanceRwf'] as num?)?.toInt() ?? 0,
          active: m['active'] == true,
          ownerName: '${m['userName'] ?? m['ownerName'] ?? ''}'.trim(),
        );
      }).toList()
        ..sort((a, b) => b.balance.compareTo(a.balance));
      if (!mounted) return;
      setState(() {
        _myCards
          ..clear()
          ..addAll(cards);
        final active = _myCards.where((c) => c.active).toList();
        if (_selectedCardId == null ||
            !_myCards.any((c) => c.id == _selectedCardId)) {
          _selectedCardId = active.isNotEmpty
              ? active.first.id
              : (_myCards.isNotEmpty ? _myCards.first.id : null);
          return;
        }
        if (active.isNotEmpty && !active.any((c) => c.id == _selectedCardId)) {
          _selectedCardId = active.first.id;
        }
      });
    });
  }

  List<_Bus> get _buses {
    final list = <_Bus>[];
    if (_routeId == null) {
      return list;
    }
    _telemetry.forEach((id, t) {
      final m = _meta[id];
      if (m != null && !m.active) return;
      final assignment = _assignments[id];
      if (assignment == null || assignment.directionId != _routeId) return;
      list.add(_Bus(live: t, meta: m));
    });
    return list;
  }

  _Route? get _selectedRoute {
    final rid = _routeId;
    if (rid == null) return null;
    for (final r in _routes) {
      if (r.id == rid) return r;
    }
    return null;
  }

  List<_SegmentOption> _segmentsForRoute(_Route route) {
    final out = <_SegmentOption>[];
    for (int i = 0; i < route.stopNames.length - 1; i++) {
      for (int j = i + 1; j < route.stopNames.length; j++) {
        out.add(
          _SegmentOption(
            fromIndex: i,
            toIndex: j,
            fromName: route.stopNames[i],
            toName: route.stopNames[j],
          ),
        );
      }
    }
    return out;
  }

  void _listenMyBookedBuses() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    _myBookingsSub = _fs
        .collection('bookings')
        .where('userId', isEqualTo: uid)
        .limit(300)
        .snapshots()
        .listen((s) {
      final next = <String>{};
      final pendingBusIds = <String>{};
      final pendingByCard = <String, int>{};
      final pendingByBusCard = <String, int>{};
      for (final d in s.docs) {
        final m = d.data();
        final status = '${m['status'] ?? ''}'.toLowerCase();
        if (status != 'booked' && status != 'paid') continue;
        final busId = '${m['busId'] ?? ''}'.trim();
        if (busId.isNotEmpty) next.add(busId);
        if (status == 'booked') {
          if (busId.isNotEmpty) pendingBusIds.add(busId);
          final cardId = '${m['cardId'] ?? ''}'.trim();
          final fare = (m['fareRwf'] as num?)?.toInt() ?? 0;
          if (cardId.isNotEmpty && fare > 0) {
            pendingByCard[cardId] = (pendingByCard[cardId] ?? 0) + fare;
            if (busId.isNotEmpty) {
              final key = '$busId|$cardId';
              pendingByBusCard[key] = (pendingByBusCard[key] ?? 0) + fare;
            }
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _bookedBusIds
          ..clear()
          ..addAll(next);
        _pendingBookedBusIds
          ..clear()
          ..addAll(pendingBusIds);
        _pendingBookedFareByCard
          ..clear()
          ..addAll(pendingByCard);
        _pendingBookedFareByBusAndCard
          ..clear()
          ..addAll(pendingByBusCard);
        _nearbyBusNotified
            .removeWhere((busId) => !_pendingBookedBusIds.contains(busId));
      });
    }, onError: (_) {});
  }

  int _pendingForCard(String? cardId) {
    final id = (cardId ?? '').trim();
    if (id.isEmpty) return 0;
    return _pendingBookedFareByCard[id] ?? 0;
  }

  int _pendingForBusAndCard(String busId, String? cardId) {
    final id = (cardId ?? '').trim();
    if (busId.trim().isEmpty || id.isEmpty) return 0;
    return _pendingBookedFareByBusAndCard['${busId.trim()}|$id'] ?? 0;
  }

  int _pendingForBusAllCards(String busId) {
    final bus = busId.trim();
    if (bus.isEmpty) return 0;
    int total = 0;
    _pendingBookedFareByBusAndCard.forEach((k, v) {
      if (k.startsWith('$bus|')) total += v;
    });
    return total;
  }

  int _fareForSegment(_Route route, _SegmentOption segment) {
    final segKey = '${segment.fromIndex}_${segment.toIndex}';
    return route.faresBySegment[segKey] ?? 0;
  }

  List<_SegmentOption> _bookableSegmentsForRoute(_Route route) {
    return _segmentsForRoute(route)
        .where((segment) => _fareForSegment(route, segment) > 0)
        .toList();
  }

  void _syncSegmentSelectionForRoute(_Route? route) {
    if (route == null) {
      _originStopIndex = null;
      _destinationStopIndex = null;
      _bookState = _BookState.selectingRoute;
      return;
    }
    final bookableSegments = _bookableSegmentsForRoute(route);
    if (bookableSegments.isEmpty) {
      _originStopIndex = null;
      _destinationStopIndex = null;
      _bookState = _BookState.selectingRoute;
      return;
    }

    if (_originStopIndex != null && _destinationStopIndex != null) {
      final from = _originStopIndex!;
      final to = _destinationStopIndex!;
      if (from >= 0 && to > from && to < route.stopNames.length) {
        final current = _SegmentOption(
          fromIndex: from,
          toIndex: to,
          fromName: route.stopNames[from],
          toName: route.stopNames[to],
        );
        if (_fareForSegment(route, current) > 0) {
          if (_bookState == _BookState.selectingRoute) {
            _bookState = _BookState.idle;
          }
          return;
        }
      }
    }

    _originStopIndex = bookableSegments.first.fromIndex;
    _destinationStopIndex = bookableSegments.first.toIndex;
    _bookState = _BookState.idle;
  }

  _SegmentOption? get _selectedSegment {
    final route = _selectedRoute;
    if (route == null ||
        _originStopIndex == null ||
        _destinationStopIndex == null) {
      return null;
    }
    if (_originStopIndex! < 0 ||
        _destinationStopIndex! < 0 ||
        _destinationStopIndex! <= _originStopIndex! ||
        _destinationStopIndex! >= route.stopNames.length) {
      return null;
    }
    final selected = _SegmentOption(
      fromIndex: _originStopIndex!,
      toIndex: _destinationStopIndex!,
      fromName: route.stopNames[_originStopIndex!],
      toName: route.stopNames[_destinationStopIndex!],
    );
    if (_fareForSegment(route, selected) <= 0) return null;
    return selected;
  }

  int _fareForBus(_Bus bus) {
    final route = _selectedRoute;
    final segment = _selectedSegment;
    if (route == null || segment == null) return 0;
    return _fareForSegment(route, segment);
  }

  int _availableSeatsForBus(_Bus bus) {
    return _availableSeatNumbersForBus(bus).length;
  }

  List<int> _availableSeatNumbersForBus(_Bus bus) {
    final total = bus.seats;
    final routeId = _routeId;
    final origin = _originStopIndex;
    final destination = _destinationStopIndex;
    if (total <= 0) return const [];
    if (routeId == null || origin == null || destination == null) {
      return List<int>.generate(total, (i) => i + 1);
    }

    final locked = <int>{};
    for (final lock in _seatLocks) {
      if (lock.busId != bus.live.id || !lock.active) continue;
      if (lock.seatNo <= 0) continue;

      if (lock.directionId != routeId) {
        locked.add(lock.seatNo);
        continue;
      }
      if (lock.originStopIndex < 0 || lock.destinationStopIndex < 0) {
        locked.add(lock.seatNo);
        continue;
      }
      final overlaps = origin < lock.destinationStopIndex &&
          lock.originStopIndex < destination;
      if (overlaps) locked.add(lock.seatNo);
    }

    final free = <int>[];
    for (int seat = 1; seat <= total; seat++) {
      if (!locked.contains(seat)) free.add(seat);
    }
    return free;
  }

  Future<void> _locate() async {
    try {
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) {
        p = await Geolocator.requestPermission();
      }
      if (p == LocationPermission.denied ||
          p == LocationPermission.deniedForever) {
        return;
      }
      final g = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high);
      _me = LatLng(g.latitude, g.longitude);
      _mapCenter = _me!;
      _map?.animateCamera(CameraUpdate.newLatLngZoom(_me!, _zoom));
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _buildMarkers() async {
    if (_mapsPaused) {
      if (!mounted) return;
      setState(() => _markers = {});
      return;
    }
    final buses = _buses.take(120).toList(growable: false);
    final t = ++_token;
    final out = <Marker>{};
    for (final b in buses) {
      if (_me != null && _pendingBookedBusIds.contains(b.live.id)) {
        final km = Geolocator.distanceBetween(
              _me!.latitude,
              _me!.longitude,
              b.live.pos.latitude,
              b.live.pos.longitude,
            ) /
            1000;
        if (km > 0.15) {
          _nearbyBusNotified.remove(b.live.id);
        } else if (km <= 0.1 && _nearbyBusNotified.add(b.live.id)) {
          unawaited(_emitUserNotification(
            type: 'bus_nearby',
            title: 'Booked bus nearby',
            body: '${b.name} (${b.plate}) is within 100m of you.',
            data: {
              'busId': b.live.id,
              'plate': b.plate,
              'distanceKm': km,
              'bookedBus': true,
            },
          ));
        }
      } else {
        _nearbyBusNotified.remove(b.live.id);
      }
      final isMyBookedBus = _pendingBookedBusIds.contains(b.live.id);
      out.add(
        Marker(
          markerId: MarkerId(b.live.id),
          position: b.live.pos,
          anchor: const Offset(0.5, 0.86),
          icon: await _iconFor(
            b,
            highlightBooked: isMyBookedBus,
            pulseOn: _bookedBusPulseOn,
          ),
          zIndexInt: isMyBookedBus ? 3000 : 1000,
          onTap: () {
            if (isMyBookedBus) {
              _showWaitingToTapPrompt(b);
              return;
            }
            _showBus(b);
          },
        ),
      );
    }
    if (_me != null) {
      out.add(
        Marker(
          markerId: const MarkerId('me'),
          position: _me!,
          infoWindow: const InfoWindow(title: 'Me'),
          icon:
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        ),
      );
    }
    if (!mounted || t != _token) return;
    setState(() => _markers = out);
    if (!_didInitialBusFocus) {
      final targetBusId = (widget.initialBusId ?? '').trim();
      if (targetBusId.isNotEmpty) {
        final target = buses.where((b) => b.live.id == targetBusId).toList();
        if (target.isNotEmpty) {
          _didInitialBusFocus = true;
          final bus = target.first;
          unawaited(_map?.animateCamera(
              CameraUpdate.newLatLngZoom(bus.live.pos, max(_zoom, 15.2))));
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _showBus(bus);
          });
        }
      }
    }
  }

  Map<String, dynamic> _extractMeta(Map<String, dynamic> deviceNode) {
    if (deviceNode[RtdbContract.metaKey] is Map) {
      final meta = Map<String, dynamic>.from(
        deviceNode[RtdbContract.metaKey] as Map,
      );
      return {
        'agencyName': meta['agencyName'] ?? deviceNode['agencyName'],
        'plateNumber': meta['plateNumber'] ?? deviceNode['plateNumber'],
        'sits': meta['sits'] ?? deviceNode['sits'],
      };
    }
    return {
      'agencyName': deviceNode['agencyName'],
      'plateNumber': deviceNode['plateNumber'],
      'sits': deviceNode['sits'],
    };
  }

  Map<String, dynamic>? _extractLatestTelemetryPoint(
    Map<String, dynamic> deviceNode,
  ) {
    final latestRaw = deviceNode[RtdbContract.latestKey];
    if (latestRaw is Map &&
        latestRaw['lat'] != null &&
        latestRaw['lng'] != null) {
      return Map<String, dynamic>.from(latestRaw);
    }

    num? latestTs;
    Map<String, dynamic>? latest;
    final historyRaw = deviceNode[RtdbContract.historyKey];
    if (historyRaw is Map) {
      historyRaw.forEach((_, cv) {
        if (cv is! Map) return;
        if (cv['lat'] == null || cv['lng'] == null) return;
        final pointTs = (cv['ts'] is num) ? cv['ts'] as num : null;
        if (latest == null ||
            (pointTs != null && (latestTs == null || pointTs > latestTs!))) {
          latest = Map<String, dynamic>.from(cv);
          latestTs = pointTs;
        }
      });
      if (latest != null) return latest;
    }

    deviceNode.forEach((ck, cv) {
      final id = ck;
      if (!id.startsWith('-') || cv is! Map) return;
      if (cv['lat'] == null || cv['lng'] == null) return;
      final pointTs = (cv['ts'] is num) ? cv['ts'] as num : null;
      if (latest == null ||
          (pointTs != null && (latestTs == null || pointTs > latestTs!))) {
        latest = Map<String, dynamic>.from(cv);
        latestTs = pointTs;
      }
    });
    return latest;
  }

  Future<void> _loadProfile() async {
    final profile = await _authService.getCurrentProfile();
    if (!mounted) return;
    setState(() => _profile = profile);
  }

  Future<void> _emitUserNotification({
    required String type,
    required String title,
    required String body,
    Map<String, dynamic>? data,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final now = FieldValue.serverTimestamp();
      await _fs.collection('user_notifications').add({
        'userId': uid,
        'type': type,
        'title': title,
        'body': body,
        'data': data ?? const {},
        'read': false,
        'createdAt': now,
        'updatedAt': now,
      });
    } catch (_) {}
  }

  Future<int> _deleteUserNotifications({
    required String uid,
    Duration? olderThan,
  }) async {
    int deleted = 0;
    while (true) {
      var query = _fs
          .collection('user_notifications')
          .where('userId', isEqualTo: uid)
          .limit(300);
      if (olderThan != null) {
        final cutoff = DateTime.now().subtract(olderThan);
        query = query.where(
          'createdAt',
          isLessThanOrEqualTo: Timestamp.fromDate(cutoff),
        );
      }
      final snap = await query.get();
      if (snap.docs.isEmpty) break;
      final batch = _fs.batch();
      for (final d in snap.docs) {
        batch.delete(d.reference);
      }
      await batch.commit();
      deleted += snap.docs.length;
      if (snap.docs.length < 300) break;
    }
    return deleted;
  }

  Future<int> _deleteUserHistory({
    required String uid,
    Duration? olderThan,
  }) async {
    int deleted = 0;
    Query<Map<String, dynamic>> query = _fs
        .collection('card_transactions')
        .where('userId', isEqualTo: uid)
        .orderBy('createdAt');

    if (olderThan != null) {
      final cutoff = DateTime.now().subtract(olderThan);
      query = query.where(
        'createdAt',
        isLessThanOrEqualTo: Timestamp.fromDate(cutoff),
      );
    }

    DocumentSnapshot<Map<String, dynamic>>? lastDoc;
    while (true) {
      var batchQuery = query.limit(300);
      if (lastDoc != null) {
        batchQuery = batchQuery.startAfterDocument(lastDoc);
      }
      final snap = await batchQuery.get();
      if (snap.docs.isEmpty) break;

      final deletableDocs = snap.docs.where((d) {
        final type = '${d.data()['type'] ?? ''}'.toLowerCase();
        return type != 'ride_payment' && type != 'top_up';
      }).toList();

      if (deletableDocs.isNotEmpty) {
        final batch = _fs.batch();
        for (final d in deletableDocs) {
          batch.delete(d.reference);
        }
        await batch.commit();
        deleted += deletableDocs.length;
      }

      if (snap.docs.length < 300) break;
      lastDoc = snap.docs.last;
    }
    return deleted;
  }

  Future<void> _clearAllNotificationsNow() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final count = await _runWithActionLoader('Clearing notifications...', () {
        return _deleteUserNotifications(uid: uid);
      });
      _showBookingToast('Cleared $count notification(s).', success: true);
    } catch (e) {
      _showBookingToast('Clear notifications failed: $e', success: false);
    }
  }

  Future<void> _clearAllHistoryNow() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final count = await _runWithActionLoader('Clearing history...', () {
        return _deleteUserHistory(uid: uid);
      });
      _showBookingToast('Cleared $count history record(s).', success: true);
    } catch (e) {
      _showBookingToast('Clear history failed: $e', success: false);
    }
  }

  Future<void> _applyAutoClearPolicies() async {
    if (_autoClearChecked) return;
    _autoClearChecked = true;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final userDoc = await _fs.collection('traffic_users').doc(uid).get();
      final data = userDoc.data() ?? const <String, dynamic>{};
      final pref = Map<String, dynamic>.from(data['preferences'] as Map? ?? const {});
      final auto = Map<String, dynamic>.from(pref['autoClear'] as Map? ?? const {});

      final notiDays = (auto['notificationsDays'] as num?)?.toInt();
      final historyDays = (auto['historyDays'] as num?)?.toInt();

      if (notiDays != null && notiDays >= 1 && notiDays <= 7) {
        await _deleteUserNotifications(
          uid: uid,
          olderThan: Duration(days: notiDays),
        );
      }
      if (historyDays != null && historyDays >= 1 && historyDays <= 7) {
        await _deleteUserHistory(
          uid: uid,
          olderThan: Duration(days: historyDays),
        );
      }
    } catch (_) {}
  }

  void _openNotifications() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          decoration: BoxDecoration(
            color: const Color(0xE910172A),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white12),
          ),
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.7,
            minChildSize: 0.45,
            maxChildSize: 0.92,
            builder: (_, c) => Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                children: [
                  Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Notifications',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          await _clearAllNotificationsNow();
                        },
                        icon: const Icon(Icons.delete_sweep_rounded, size: 18),
                        label: const Text('Clear all'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: _fs
                          .collection('user_notifications')
                          .where('userId', isEqualTo: uid)
                          .limit(200)
                          .snapshots(),
                      builder: (context, snap) {
                        if (snap.hasError) {
                          return Center(
                            child: Text(
                              'Notifications failed: ${snap.error}',
                              style: const TextStyle(color: Colors.white70),
                            ),
                          );
                        }
                        if (!snap.hasData) {
                          return const Center(
                            child: CircularProgressIndicator(strokeWidth: 2),
                          );
                        }
                        final docs = [...snap.data!.docs]..sort((a, b) {
                            final ta = (a.data()['createdAt'] as Timestamp?)
                                    ?.millisecondsSinceEpoch ??
                                0;
                            final tb = (b.data()['createdAt'] as Timestamp?)
                                    ?.millisecondsSinceEpoch ??
                                0;
                            return tb.compareTo(ta);
                          });
                        if (docs.isEmpty) {
                          return const Center(
                            child: Text(
                              'No notifications yet.',
                              style: TextStyle(color: Colors.white70),
                            ),
                          );
                        }
                        return ListView.builder(
                          controller: c,
                          itemCount: docs.length,
                          itemBuilder: (_, i) {
                            final m = docs[i].data();
                            final read = m['read'] == true;
                            final ts = m['createdAt'] as Timestamp?;
                            return ListTile(
                              dense: true,
                              onTap: () {
                                docs[i].reference.set({
                                  'read': true,
                                  'updatedAt': FieldValue.serverTimestamp(),
                                }, SetOptions(merge: true));
                              },
                              leading: Icon(
                                read
                                    ? Icons.notifications_none_rounded
                                    : Icons.notifications_active_rounded,
                                color: read
                                    ? Colors.white54
                                    : const Color(0xFF60A5FA),
                              ),
                              title: Text(
                                '${m['title'] ?? 'Notification'}',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight:
                                      read ? FontWeight.w500 : FontWeight.w700,
                                ),
                              ),
                              subtitle: Text(
                                '${m['body'] ?? ''}\n${_timeAgo(ts)}',
                                style: const TextStyle(color: Colors.white70),
                              ),
                              isThreeLine: true,
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<BitmapDescriptor> _iconFor(
    _Bus b, {
    bool highlightBooked = false,
    bool pulseOn = false,
  }) async {
    final markerTitle = '${b.name} | ${b.plate}'.trim();
    final key = '${b.live.id}|$markerTitle|$highlightBooked|$pulseOn';
    final cached = _icons[key];
    if (cached != null) return cached;

    final bytes = await _buildBusMarkerBytes(
      markerTitle,
      highlightBooked: highlightBooked,
      pulseOn: pulseOn,
    );
    final out = BitmapDescriptor.fromBytes(bytes);
    _icons[key] = out;
    return out;
  }

  Future<Uint8List> _buildBusMarkerBytes(
    String label, {
    bool highlightBooked = false,
    bool pulseOn = false,
  }) async {
    const double width = 260;
    const double height = 120;
    const double chipH = 40;
    const double chipRadius = 14;
    const double pinR = 22;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    final chipRect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(10, 4, width - 20, chipH),
      const Radius.circular(chipRadius),
    );

    final chipPaint = Paint()..color = const Color(0xF2FFFFFF);
    canvas.drawRRect(chipRect, chipPaint);
    canvas.drawRRect(
      chipRect,
      Paint()
        ..color = const Color(0x33000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );

    final safeLabel = label.isEmpty ? 'Bus' : label;
    final textPainter = TextPainter(
      text: TextSpan(
        text: safeLabel,
        style: const TextStyle(
          color: Color(0xFF111827),
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '...',
    )..layout(maxWidth: width - 34);
    textPainter.paint(
      canvas,
      Offset((width - textPainter.width) / 2, 4 + (chipH - textPainter.height) / 2),
    );

    const pinCenter = Offset(width / 2, 76);
    if (highlightBooked) {
      final baseRadius = pulseOn ? 36.0 : 30.0;
      canvas.drawCircle(
        pinCenter,
        baseRadius,
        Paint()..color = const Color(0x9922D3EE),
      );
      canvas.drawCircle(
        pinCenter,
        baseRadius + 7,
        Paint()..color = const Color(0x4422D3EE),
      );
    }
    canvas.drawCircle(
      pinCenter,
      pinR,
      Paint()..color = const Color(0xCC0F172A),
    );
    canvas.drawCircle(
      pinCenter,
      pinR,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    final carPainter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(Icons.directions_car_filled_rounded.codePoint),
        style: TextStyle(
          fontSize: 20,
          fontFamily: Icons.directions_car_filled_rounded.fontFamily,
          package: Icons.directions_car_filled_rounded.fontPackage,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    carPainter.paint(
      canvas,
      Offset(pinCenter.dx - carPainter.width / 2, pinCenter.dy - carPainter.height / 2),
    );

    final pointerPath = Path()
      ..moveTo(pinCenter.dx - 9, 95)
      ..lineTo(pinCenter.dx + 9, 95)
      ..lineTo(pinCenter.dx, 112)
      ..close();
    canvas.drawPath(pointerPath, Paint()..color = const Color(0xCC0F172A));
    canvas.drawPath(
      pointerPath,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );

    final image = await recorder.endRecording().toImage(
          width.toInt(),
          height.toInt(),
        );
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  String _short(String s) {
    final t = s.split('_').first.replaceAll(RegExp(r'[^A-Za-z]'), '');
    if (t.isEmpty) return '??';
    return t.length < 2
        ? t.toUpperCase()
        : '${t[0].toUpperCase()}${t[1].toLowerCase()}';
  }

  Color _agencyColor(String agencyRaw) {
    final key = agencyRaw.trim().toLowerCase();
    if (key.isEmpty) return const Color(0xFF3B82F6);
    final palette = <Color>[
      const Color(0xFF3B82F6),
      const Color(0xFFEF4444),
      const Color(0xFF22C55E),
      const Color(0xFFF59E0B),
      const Color(0xFF06B6D4),
      const Color(0xFFEC4899),
      const Color(0xFF8B5CF6),
      const Color(0xFF14B8A6),
    ];
    return palette[key.hashCode.abs() % palette.length];
  }

  int _i(Object? v) => (v is num) ? v.toInt() : int.tryParse('$v') ?? 0;
  double? _toDouble(Object? v) =>
      (v is num) ? v.toDouble() : double.tryParse('$v');
  String _friendlyBookingError(Object e) {
    if (e is FirebaseFunctionsException) {
      final msg = (e.message ?? '').toLowerCase();
      if (e.code == 'not-found' && msg.contains('card')) {
        return 'Card not found';
      }
      if (e.code == 'failed-precondition' && msg.contains('insufficient')) {
        return 'Insufficient balance';
      }
      if (e.code == 'already-exists' &&
          (msg.contains('seat') || msg.contains('occupied'))) {
        return 'Seat already booked';
      }
      if (e.code == 'unauthenticated') {
        return 'Please sign in again, then retry';
      }
    }

    final raw = e.toString().toLowerCase();
    if (raw.contains('card not found')) return 'Card not found';
    if (raw.contains('insufficient')) return 'Insufficient balance';
    if (raw.contains('seat already') || raw.contains('occupied')) {
      return 'Seat already booked';
    }
    if (raw.contains('unauthenticated') || raw.contains('sign in')) {
      return 'Please sign in again, then retry';
    }
    return 'Booking failed. Please try again';
  }

  void _showBookingToast(String message, {required bool success}) {
    if (!mounted) return;
    showSpotlightToast(context, message, success: success);
  }

  void _showWaitingToTapPrompt(_Bus b) {
    if (!mounted) return;
    final cardId = _session?.card ?? _selectedCardId ?? '';
    final pendingBusAmount = _pendingForBusAndCard(b.live.id, cardId);
    final amountRwf = pendingBusAmount > 0
        ? pendingBusAmount
        : max(
            _pendingForBusAllCards(b.live.id),
            (_session?.busId == b.live.id ? _session!.totalDeductRwf : 0),
          );
    showSpotlightToast(
      context,
      'Waiting to tap on ${b.name} (${b.plate}). Amount: RWF $amountRwf',
      success: true,
      duration: const Duration(seconds: 5),
    );
  }

  Future<void> _handleProfileMenuAction(_ProfileAction action) async {
    switch (action) {
      case _ProfileAction.profile:
        final user = FirebaseAuth.instance.currentUser;
        final role = _profile == null
            ? 'unknown'
            : TrafficUserProfile.roleToString(_profile!.role);
        final preferredCard = _selectedCardId ??
            (_myCards.isNotEmpty ? _myCards.first.id : '');
        final cardNumber = preferredCard.isEmpty
            ? '-'
            : (preferredCard.startsWith('rfid_')
                ? preferredCard.substring(5)
                : preferredCard);
        final username = (_profile?.displayName ?? user?.displayName ?? '').trim();
        Widget infoRow({
          required IconData icon,
          required String label,
          required String value,
        }) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            ),
            child: Row(
              children: [
                Icon(icon, size: 18, color: const Color(0xFF93C5FD)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        value.isEmpty ? '-' : value,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }
        if (!mounted) return;
        await showModalBottomSheet<void>(
          context: context,
          backgroundColor: const Color(0xFF0B1220),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          builder: (ctx) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Profile',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 14),
                  infoRow(
                    icon: Icons.email_rounded,
                    label: 'Email',
                    value: user?.email ?? '-',
                  ),
                  const SizedBox(height: 10),
                  infoRow(
                    icon: Icons.person_rounded,
                    label: 'Username',
                    value: username.isEmpty ? '-' : username,
                  ),
                  const SizedBox(height: 10),
                  infoRow(
                    icon: Icons.credit_card_rounded,
                    label: 'Card Number',
                    value: cardNumber,
                  ),
                  const SizedBox(height: 10),
                  infoRow(
                    icon: Icons.verified_user_rounded,
                    label: 'Role',
                    value: role,
                  ),
                ],
              ),
            ),
          ),
        );
        break;
      case _ProfileAction.logout:
        await FirebaseAuth.instance.signOut();
        if (!mounted) return;
        context.go(AppRoutes.login);
        break;
    }
  }

  Future<void> _zoomBy(double delta) async {
    final next = (_zoom + delta).clamp(9.5, 19.5);
    _zoom = next;
    await _map?.animateCamera(CameraUpdate.zoomTo(next));
    if (mounted) setState(() {});
  }

  double _kmd(_Bus b) {
    final from = _me ?? _mapCenter;
    return Geolocator.distanceBetween(from.latitude, from.longitude,
            b.live.pos.latitude, b.live.pos.longitude) /
        1000;
  }

  String _eta(_Bus b) {
    final s = b.live.speed ?? 0;
    if (s <= 0.1) return 'ETA --';
    return 'ETA ${((_kmd(b) / s) * 60).round()}m';
  }

  Color _seatColor(int s) => s < 5
      ? const Color(0xFFEF4444)
      : (s <= 10 ? const Color(0xFFF59E0B) : const Color(0xFF22C55E));

  Future<void> _book(_Bus b, {BuildContext? parentSheetContext}) async {
    final route = _selectedRoute;
    final segment = _selectedSegment;
    if (_routeId == null || route == null) {
      setState(() => _bookState = _BookState.selectingRoute);
      _showBookingToast('Select a direction first', success: false);
      return;
    }
    if (segment == null) {
      setState(() => _bookState = _BookState.selectingRoute);
      _showBookingToast('Select origin and destination stops first',
          success: false);
      return;
    }
    final activeCards = <_CardInfo>[];
    final seenCardIds = <String>{};
    for (final c in _myCards) {
      if (!c.active) continue;
      if (!seenCardIds.add(c.id)) continue;
      activeCards.add(c);
    }
    String selectedCard = _selectedCardId ?? '';
    if (activeCards.isNotEmpty) {
      if (selectedCard.isEmpty ||
          !activeCards.any((c) => c.id == selectedCard)) {
        selectedCard = activeCards.first.id;
      }
    }
    String manualCard = '';
    String seatCountText = '';
    bool useOtherCard = false;
    String cleanCardNumber(String value) {
      final trimmed = value.trim();
      if (trimmed.toLowerCase().startsWith('rfid_')) {
        return trimmed.substring(5);
      }
      return trimmed;
    }
    final req = await showModalBottomSheet<_Req>(
      context: context,
      backgroundColor: const Color(0xFF0B1220),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setM) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Book Seat',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 14),
                if (activeCards.isNotEmpty) ...[
                  DropdownButtonFormField<String>(
                    initialValue: selectedCard.isEmpty
                        ? activeCards.first.id
                        : selectedCard,
                    dropdownColor: const Color(0xFF0F172A),
                    decoration: const InputDecoration(
                      labelText: 'Select card',
                      labelStyle: TextStyle(color: Colors.white70),
                      filled: true,
                      fillColor: Color(0x1AFFFFFF),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(12)),
                        borderSide: BorderSide(color: Colors.white12),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(12)),
                        borderSide: BorderSide(color: Colors.white12),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(12)),
                        borderSide: BorderSide(color: Color(0xFF93C5FD)),
                      ),
                    ),
                    items: activeCards
                        .map(
                          (c) => DropdownMenuItem<String>(
                            value: c.id,
                            child: Text(
                              '${cleanCardNumber(c.id)} - RWF ${c.balance}',
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setM(() => selectedCard = v ?? ''),
                  ),
                  const SizedBox(height: 10),
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => setM(() => useOtherCard = !useOtherCard),
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(12),
                          border:
                              Border.all(color: Colors.white.withValues(alpha: 0.1)),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              useOtherCard
                                  ? Icons.toggle_on_rounded
                                  : Icons.toggle_off_rounded,
                              size: 26,
                              color: useOtherCard
                                  ? const Color(0xFF93C5FD)
                                  : Colors.white54,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              'Use other card',
                              style: TextStyle(
                                color: useOtherCard
                                    ? const Color(0xFFBFDBFE)
                                    : Colors.white70,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
                if (activeCards.isEmpty || useOtherCard) ...[
                  TextField(
                    style: const TextStyle(color: Colors.white),
                    onChanged: (v) => setM(() => manualCard = cleanCardNumber(v)),
                    decoration: const InputDecoration(
                      labelText: 'Other card number',
                      labelStyle: TextStyle(color: Colors.white70),
                      filled: true,
                      fillColor: Color(0x1AFFFFFF),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(12)),
                        borderSide: BorderSide(color: Colors.white12),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(12)),
                        borderSide: BorderSide(color: Colors.white12),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(12)),
                        borderSide: BorderSide(color: Color(0xFF93C5FD)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                TextField(
                  style: const TextStyle(color: Colors.white),
                  keyboardType: TextInputType.number,
                  onChanged: (v) => setM(() => seatCountText = v),
                  decoration: const InputDecoration(
                    labelText: 'How many seats?',
                    hintText: 'Example: 1, 2, 3',
                    labelStyle: TextStyle(color: Colors.white70),
                    filled: true,
                    fillColor: Color(0x1AFFFFFF),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(12)),
                      borderSide: BorderSide(color: Colors.white12),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(12)),
                      borderSide: BorderSide(color: Colors.white12),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(12)),
                      borderSide: BorderSide(color: Color(0xFF93C5FD)),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      final seatCount = int.tryParse(seatCountText.trim()) ?? 0;
                      final cardId = ((_myCards.isNotEmpty && !useOtherCard)
                              ? selectedCard
                              : manualCard)
                          .trim();
                      if (seatCount <= 0 || cardId.isEmpty) return;
                      final freeSeats = _availableSeatNumbersForBus(b);
                      if (freeSeats.length < seatCount) {
                        _showBookingToast(
                          'Only ${freeSeats.length} seat(s) available on this segment.',
                          success: false,
                        );
                        return;
                      }
                      final chosen = freeSeats.take(seatCount).toList();
                      FocusManager.instance.primaryFocus?.unfocus();
                      // Close sheet first so request progress is visible in page overlay.
                      Navigator.pop(ctx, _Req(card: cardId, seats: chosen));
                    },
                    child: const Text('Confirm'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (req == null) return;
    if (parentSheetContext != null && Navigator.of(parentSheetContext).canPop()) {
      Navigator.of(parentSheetContext).pop();
    }
    final totalEstimate = _fareForBus(b) * req.seats.length;
    int? cardBalance;
    _CardInfo? selectedCardInfo;
    for (final card in _myCards) {
      if (card.id == req.card) {
        selectedCardInfo = card;
        cardBalance = card.balance;
        break;
      }
    }
    if (cardBalance == null) {
      try {
        final cardDoc = await _fs.collection('cards').doc(req.card).get();
        if (cardDoc.exists) {
          cardBalance = (cardDoc.data()?['balanceRwf'] as num?)?.toInt();
        }
      } catch (_) {}
    }
    if (cardBalance != null && totalEstimate > cardBalance) {
      final isMultiSeat = req.seats.length > 1;
      final msg = isMultiSeat
          ? 'Insufficient balance. Reduce seats or top up card.'
          : 'Insufficient balance for this seat. Please top up card.';
      _showBookingToast(msg, success: false);
      unawaited(_emitUserNotification(
        type: 'booking_failed',
        title: 'Booking failed',
        body: msg,
        data: {
          'reason': 'insufficient_balance',
          'busId': b.live.id,
          'cardId': req.card,
          'seatsRequested': req.seats.length,
          'requiredRwf': totalEstimate,
          'balanceRwf': cardBalance,
        },
      ));
      if (mounted) {
        setState(() {
          _bookState = _BookState.idle;
          _bookErr = null;
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _bookState = _BookState.booking;
      _bookErr = null;
    });
    try {
      await _runWithActionLoader('Booking seats...', () async {
        final user = FirebaseAuth.instance.currentUser;
        if (user == null) {
          throw Exception('Sign in required before booking.');
        }
        // Force-refresh ID token so callable functions always receive auth.
        await user.getIdToken(true);
        final groupId =
            'g_${user.uid}_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(9999)}';
        final bookedIds = <String>[];
        final failedSeats = <int>[];
        for (final seat in req.seats) {
          final idem =
              '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(99999)}_$seat';
          final payload = {
            'uid': user.uid,
            'busId': b.live.id,
            'routeId': _routeId,
            'directionId': _routeId,
            'originStopIndex': segment.fromIndex,
            'destinationStopIndex': segment.toIndex,
            'originStopName': segment.fromName,
            'destinationStopName': segment.toName,
            'fareRwf': _fareForBus(b),
            'cardId': req.card,
            'seatNo': seat,
            'bookingGroupId': groupId,
            'idempotencyKey': idem,
          };
          try {
            dynamic res;
            try {
              final fn = _fx.httpsCallable('bookSeat');
              res = await fn.call(payload);
            } on FirebaseFunctionsException catch (e) {
              if (e.code != 'unauthenticated') rethrow;
              final fallbackFn = _fx.httpsCallable('bookSeatV1');
              res = await fallbackFn.call(payload);
            }
            final raw = res.data;
            if (raw is Map) {
              final data = Map<String, dynamic>.from(
                  raw.map((k, v) => MapEntry('$k', v)));
              final id = '${data['bookingId'] ?? ''}';
              if (id.isNotEmpty) bookedIds.add(id);
            } else {
              failedSeats.add(seat);
            }
          } catch (_) {
            failedSeats.add(seat);
          }
        }

        if (bookedIds.isEmpty) {
          throw Exception('No seats were booked. Try different seats.');
        }

        setState(() {
          final successfulSeats =
              req.seats.where((s) => !failedSeats.contains(s)).toList();
          final farePerSeat = _fareForBus(b);
          final totalDeductRwf = farePerSeat * successfulSeats.length;
          _session = _BookSession(
            ids: bookedIds,
            groupId: groupId,
            busId: b.live.id,
            seats: successfulSeats,
            card: req.card,
            totalDeductRwf: totalDeductRwf,
          );
          _bookState = _BookState.booked;
          _selectedCardId = req.card;
        });
        _bookedBusPulseOn = true;
        unawaited(_buildMarkers());

        final bookedCount = bookedIds.length;
        if (failedSeats.isEmpty) {
          _showBookingToast(
            '$bookedCount seat(s) booked. Waiting for tap on bus',
            success: true,
          );
        } else {
          _showBookingToast(
            '$bookedCount booked, failed seats: ${failedSeats.join(', ')}',
            success: false,
          );
        }
      });
    } catch (e) {
      final friendly = _friendlyBookingError(e);
      setState(() {
        _bookState = _BookState.idle;
        _bookErr = null;
      });
      _showBookingToast(friendly, success: false);
      unawaited(_emitUserNotification(
        type: 'booking_failed',
        title: 'Booking failed',
        body: friendly,
        data: {
          'busId': b.live.id,
          'cardId': req.card,
          'seatsRequested': req.seats.length,
        },
      ));
    }
  }

  void _showBus(_Bus b) {
    final route = _selectedRoute;
    final segment = _selectedSegment;
    final fare = _fareForBus(b);
    final freeSeats = _availableSeatsForBus(b);
    final totalSeats = b.seats;
    final agencyColor = _agencyColor(b.meta?.agency ?? b.name);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(99))),
                const SizedBox(height: 10),
                Text(b.name,
                    style: TextStyle(
                        color: agencyColor,
                        fontWeight: FontWeight.w700,
                        fontSize: 18)),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  _pill(Icons.pin, b.plate),
                  _pill(Icons.event_seat_rounded, '$freeSeats/$totalSeats free',
                      c: _seatColor(freeSeats)),
                  _pill(Icons.schedule, _eta(b)),
                  if (route != null)
                    _pill(
                      Icons.alt_route_rounded,
                      '${route.corridorName} (${route.directionLabel})',
                    ),
                  if (segment != null)
                    _pill(
                      Icons.route_rounded,
                      '${segment.fromName} -> ${segment.toName}',
                    ),
                  if (segment != null)
                    _pill(Icons.payments_rounded, 'RWF $fare'),
                ]),
                const SizedBox(height: 14),
                SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                        onPressed: (segment == null || freeSeats <= 0)
                            ? null
                            : () => _book(b, parentSheetContext: sheetCtx),
                        icon: const Icon(Icons.event_seat_rounded),
                        label: Text(segment == null
                            ? 'Select stop chunk first'
                            : (freeSeats <= 0
                                ? 'No free seats now'
                                : 'Book seat')))),
              ]),
        ),
      ),
    );
  }

  Widget _pill(IconData i, String t, {Color c = Colors.white}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
            color: Colors.white10, borderRadius: BorderRadius.circular(99)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(i, size: 13, color: Colors.white70),
          const SizedBox(width: 6),
          Text(t,
              style: TextStyle(
                  color: c, fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      );

  void _openLive() {
    _Filter f = _Filter.agency;
    String q = '';
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setM) {
          final list = _buses
              .where((b) =>
                  q.isEmpty ||
                  b.name.toLowerCase().contains(q.toLowerCase()) ||
                  b.plate.toLowerCase().contains(q.toLowerCase()))
              .toList();
          if (f == _Filter.agency) {
            list.sort((a, b) => a.name.compareTo(b.name));
          }
          if (f == _Filter.nearest) {
            list.sort((a, b) => _kmd(a).compareTo(_kmd(b)));
          }
          if (f == _Filter.eta) list.sort((a, b) => _eta(a).compareTo(_eta(b)));
          return SafeArea(
            child: Container(
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              decoration: BoxDecoration(
                  color: const Color(0xE910172A),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.white12)),
              child: DraggableScrollableSheet(
                expand: false,
                initialChildSize: 0.64,
                minChildSize: 0.4,
                maxChildSize: 0.9,
                builder: (_, c) => Column(children: [
                  const SizedBox(height: 10),
                  Container(
                      width: 42,
                      height: 4,
                      decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(99))),
                  const SizedBox(height: 10),
                  const Text('Live Buses',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 19,
                          fontWeight: FontWeight.w700)),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                    child: TextField(
                      onChanged: (v) => setM(() => q = v),
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'Search agency or plate',
                        hintStyle: const TextStyle(color: Colors.white54),
                        prefixIcon:
                            const Icon(Icons.search, color: Colors.white70),
                        filled: true,
                        fillColor: Colors.white10,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none),
                      ),
                    ),
                  ),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    _fChip('Agency', f == _Filter.agency,
                        () => setM(() => f = _Filter.agency)),
                    const SizedBox(width: 8),
                    _fChip('Nearest', f == _Filter.nearest,
                        () => setM(() => f = _Filter.nearest)),
                    const SizedBox(width: 8),
                    _fChip('ETA', f == _Filter.eta,
                        () => setM(() => f = _Filter.eta)),
                  ]),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.builder(
                      controller: c,
                      itemCount: list.length,
                      itemBuilder: (_, i) {
                        final b = list[i];
                        return ListTile(
                          dense: true,
                          onTap: () async {
                            Navigator.pop(context);
                            _zoom = 13;
                            await _map?.animateCamera(
                                CameraUpdate.newLatLngZoom(b.live.pos, _zoom));
                            if (mounted) _showBus(b);
                          },
                          leading: const CircleAvatar(
                              backgroundColor: Color(0x1AFFFFFF),
                              child: Icon(Icons.directions_bus_filled_rounded,
                                  color: Colors.white)),
                          title: Text(b.name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              )),
                          subtitle: Text(
                              '${_kmd(b).toStringAsFixed(1)} km - ${_eta(b)}',
                              style: const TextStyle(color: Colors.white70)),
                          trailing: Text(
                              '${_availableSeatsForBus(b)}/${b.seats} free',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700)),
                        );
                      },
                    ),
                  ),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }

  void _openMyCards() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          decoration: BoxDecoration(
            color: const Color(0xE910172A),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white12),
          ),
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.7,
            minChildSize: 0.45,
            maxChildSize: 0.92,
            builder: (_, c) => Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                children: [
                  Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'My Cards',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 132,
                    child: _myCards.isEmpty
                        ? const Center(
                            child: Text(
                              'No active cards linked yet.',
                              style: TextStyle(color: Colors.white70),
                            ),
                          )
                        : ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: _myCards.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: 10),
                            itemBuilder: (_, i) {
                              final card = _myCards[i];
                              final selected = card.id == _selectedCardId;
                              final cleanId = card.id.startsWith('rfid_')
                                  ? card.id.substring(5)
                                  : card.id;
                              return InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: () {
                                  setState(() => _selectedCardId = card.id);
                                },
                                child: Container(
                                  width: MediaQuery.of(context).size.width - 52,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: selected
                                          ? const Color(0xFF3B82F6)
                                          : Colors.white12,
                                      width: selected ? 1.6 : 1,
                                    ),
                                    gradient: const LinearGradient(
                                      colors: [
                                        Color(0xFF111827),
                                        Color(0xFF0B1220)
                                      ],
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              cleanId,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.w800,
                                                letterSpacing: 2.0,
                                                fontSize: 18,
                                                fontFamily: 'monospace',
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Icon(
                                            card.active
                                                ? Icons.verified_rounded
                                                : Icons.warning_amber_rounded,
                                            size: 14,
                                            color: card.active
                                                ? const Color(0xFF86EFAC)
                                                : const Color(0xFFFCA5A5),
                                          ),
                                          const SizedBox(width: 5),
                                          Text(
                                            card.active ? 'Active' : 'Inactive',
                                            style: TextStyle(
                                              color: card.active
                                                  ? const Color(0xFF86EFAC)
                                                  : const Color(0xFFFCA5A5),
                                              fontSize: 11,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Text(
                                            'RWF ${card.balance}',
                                            style: const TextStyle(
                                              color: Color(0xFF93C5FD),
                                              fontWeight: FontWeight.w800,
                                              fontSize: 13,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        card.ownerName.isEmpty
                                            ? (_profile?.displayName.isNotEmpty ==
                                                    true
                                                ? _profile!.displayName
                                                : 'Card owner')
                                            : card.ownerName,
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 12,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        (_profile?.email ?? '').trim().isEmpty
                                            ? 'No email'
                                            : _profile!.email,
                                        style: const TextStyle(
                                          color: Colors.white54,
                                          fontSize: 11,
                                        ),
                                      ),
                                      const Spacer(),
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.end,
                                        children: [
                                          Text(
                                            '-${_pendingForCard(card.id)}',
                                            style: const TextStyle(
                                              color: Color(0xFFEF4444),
                                              fontWeight: FontWeight.w800,
                                              fontSize: 11,
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Text(
                                            '${max(0, card.balance - _pendingForCard(card.id))}',
                                            style: const TextStyle(
                                              color: Colors.white54,
                                              fontWeight: FontWeight.w700,
                                              fontSize: 11,
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Text(
                                            '${card.balance}',
                                            style: const TextStyle(
                                              color: Color(0xFF93C5FD),
                                              fontWeight: FontWeight.w800,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 10),
                  DefaultTabController(
                    length: 2,
                    child: Expanded(
                      child: Column(
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.white10,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const TabBar(
                              dividerColor: Colors.transparent,
                              tabs: [
                                Tab(text: 'History'),
                                Tab(text: 'Bookings'),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                          Expanded(
                            child: TabBarView(
                              children: [
                                _buildHistoryTab(uid: uid),
                                _buildBookingsTab(uid: uid),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHistoryTab({required String uid}) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _fs
          .collection('card_transactions')
          .where('userId', isEqualTo: uid)
          .orderBy('createdAt', descending: true)
          .limit(300)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
            child: Text(
              'History failed: ${snap.error}',
              style: const TextStyle(color: Colors.white70),
            ),
          );
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        var docs = snap.data!.docs;
        if (_selectedCardId != null) {
          docs = docs
              .where((d) => '${d.data()['cardId'] ?? ''}' == _selectedCardId)
              .toList();
        }
        final filtered = docs.where((d) {
          final m = d.data();
          final busId = '${m['busId'] ?? ''}'.trim();
          final plate = _meta[busId]?.plate.isNotEmpty == true
              ? _meta[busId]!.plate
              : (_telemetry[busId]?.plateNumber ?? '');
          final ts = m['createdAt'] as Timestamp?;
          return _matchesHistorySearch(
            query: _historySearchQuery,
            busId: busId,
            plate: plate,
            ts: ts,
          );
        }).toList();
        return Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    onChanged: (v) =>
                        setState(() => _historySearchQuery = v.trim()),
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Search bus, plate, date',
                      hintStyle: const TextStyle(color: Colors.white54),
                      prefixIcon: const Icon(Icons.manage_search_rounded,
                          color: Colors.white70),
                      filled: true,
                      fillColor: const Color(0xB31F2937),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: filtered.isEmpty
                      ? null
                      : () => _exportHistoryPdf(filtered),
                  icon: const Icon(Icons.download_rounded),
                  tooltip: 'Download PDF',
                ),
                const SizedBox(width: 6),
                IconButton(
                  onPressed: () async {
                    await _clearAllHistoryNow();
                  },
                  icon: const Icon(Icons.delete_sweep_rounded),
                  tooltip: 'Clear all',
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(
                      child: Text(
                        'No history found.',
                        style: TextStyle(color: Colors.white70),
                      ),
                    )
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final m = filtered[i].data();
                        final typeRaw = '${m['type'] ?? ''}'.toLowerCase();
                        final type = typeRaw == 'top_up'
                            ? 'Top up'
                            : (typeRaw == 'ride_payment'
                                ? 'Ride payment'
                                : (typeRaw.isEmpty ? '-' : typeRaw));
                        final delta = (m['deltaRwf'] as num?)?.toInt() ??
                            (m['amountDeltaRwf'] as num?)?.toInt() ??
                            0;
                        final bal = (m['balanceAfter'] as num?)?.toInt() ??
                            (m['balanceAfterRwf'] as num?)?.toInt() ??
                            0;
                        final ts = m['createdAt'] as Timestamp?;
                        final busId = '${m['busId'] ?? ''}'.trim();
                        final plate = _meta[busId]?.plate.isNotEmpty == true
                            ? _meta[busId]!.plate
                            : (_telemetry[busId]?.plateNumber ?? '-');
                        final seat = (m['seatNo'] as num?)?.toInt();
                        final from = '${m['originStopName'] ?? ''}'.trim();
                        final to = '${m['destinationStopName'] ?? ''}'.trim();
                        final chunk = from.isNotEmpty && to.isNotEmpty
                            ? '$from -> $to'
                            : '';
                        final color = typeRaw == 'top_up'
                            ? const Color(0xFF22C55E)
                            : (typeRaw == 'ride_payment'
                                ? const Color(0xFFEF4444)
                                : const Color(0xFF3B82F6));
                        final deltaText = delta > 0 ? '+$delta' : '$delta';
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.white10,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 16,
                                backgroundColor: color.withValues(alpha: 0.18),
                                child: Icon(
                                  typeRaw == 'top_up'
                                      ? Icons.arrow_downward_rounded
                                      : (typeRaw == 'ride_payment'
                                          ? Icons.directions_bus_filled_rounded
                                          : Icons.bookmark_added_rounded),
                                  color: color,
                                  size: 18,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      type,
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w700),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${busId.isEmpty ? '-' : busId} | $plate'
                                      '${seat == null ? '' : ' | #$seat'}'
                                      '${chunk.isEmpty ? '' : '\n$chunk'}'
                                      '\n${_timeAgo(ts)}',
                                      style: const TextStyle(
                                          color: Colors.white70, fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 10),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    'RWF $deltaText',
                                    style: TextStyle(
                                        color: color,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 12),
                                  ),
                                  Text(
                                    'Bal $bal',
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 11),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildBookingsTab({required String uid}) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _fs
          .collection('bookings')
          .where('userId', isEqualTo: uid)
          .orderBy('createdAt', descending: true)
          .limit(300)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
            child: Text(
              'Bookings failed: ${snap.error}',
              style: const TextStyle(color: Colors.white70),
            ),
          );
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        final docs = snap.data!.docs
            .where(
                (d) => '${d.data()['status'] ?? ''}'.toLowerCase() == 'booked')
            .toList();
        final filtered = docs.where((d) {
          final m = d.data();
          final busId = '${m['busId'] ?? ''}'.trim();
          final plate = _meta[busId]?.plate.isNotEmpty == true
              ? _meta[busId]!.plate
              : (_telemetry[busId]?.plateNumber ?? '');
          final from = '${m['originStopName'] ?? ''}'.trim();
          final to = '${m['destinationStopName'] ?? ''}'.trim();
          final q = _bookingsSearchQuery.trim().toLowerCase();
          if (q.isEmpty) return true;
          return '$busId $plate $from $to'.toLowerCase().contains(q);
        }).toList();
        return Column(
          children: [
            TextField(
              onChanged: (v) => setState(() => _bookingsSearchQuery = v.trim()),
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Find bus, plate, or stop',
                hintStyle: const TextStyle(color: Colors.white54),
                prefixIcon: const Icon(
                  Icons.travel_explore_rounded,
                  color: Colors.white70,
                ),
                filled: true,
                fillColor: const Color(0xB31F2937),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(
                      child: Text(
                        'No bookings yet.',
                        style: TextStyle(color: Colors.white70),
                      ),
                    )
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final m = filtered[i].data();
                        final busId = '${m['busId'] ?? '-'}';
                        final plate = _meta[busId]?.plate.isNotEmpty == true
                            ? _meta[busId]!.plate
                            : (_telemetry[busId]?.plateNumber ?? '-');
                        final seat = (m['seatNo'] as num?)?.toInt() ?? 0;
                        final fare = (m['fareRwf'] as num?)?.toInt() ?? 0;
                        final from = '${m['originStopName'] ?? '-'}';
                        final to = '${m['destinationStopName'] ?? '-'}';
                        final agencyColor =
                            _agencyColor(_meta[busId]?.agency ?? busId);
                        return Container(
                          margin: const EdgeInsets.only(bottom: 9),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xB31F2937),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 16,
                                backgroundColor:
                                    agencyColor.withValues(alpha: 0.18),
                                child: Icon(
                                  Icons.event_seat_rounded,
                                  size: 17,
                                  color: agencyColor,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '$busId  $plate',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '$from -> $to   RWF $fare',
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white10,
                                  borderRadius: BorderRadius.circular(99),
                                  border: Border.all(color: Colors.white24),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.chair_alt_rounded,
                                      size: 12,
                                      color: Colors.white70,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      '$seat',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  bool _matchesHistorySearch({
    required String query,
    required String busId,
    required String plate,
    required Timestamp? ts,
  }) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final date = ts == null ? '' : _formatTsForSearch(ts);
    return '$busId $plate $date'.toLowerCase().contains(q);
  }

  String _formatTsForSearch(Timestamp ts) {
    final d = ts.toDate();
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  Future<void> _exportHistoryPdf(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) async {
    try {
      final pdf = pw.Document();
      final now = DateTime.now();
      final y = now.year.toString().padLeft(4, '0');
      final m = now.month.toString().padLeft(2, '0');
      final d = now.day.toString().padLeft(2, '0');
      final hh = now.hour.toString().padLeft(2, '0');
      final mm = now.minute.toString().padLeft(2, '0');
      final ymd = '$y$m$d';
      final file = 'msafiri_history_${ymd}_$hh$mm.pdf';

      pdf.addPage(
        pw.MultiPage(
          build: (_) => [
            pw.Text(
              'Msafiri History Report',
              style: pw.TextStyle(
                fontSize: 18,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 8),
            pw.Text('Generated: ${now.toIso8601String()}'),
            pw.SizedBox(height: 10),
            pw.TableHelper.fromTextArray(
              headers: const ['Type', 'Bus', 'Plate', 'Seat', 'Amount', 'Date'],
              data: docs.map((d) {
                final m = d.data();
                final typeRaw = '${m['type'] ?? ''}'.toLowerCase();
                final type = typeRaw == 'top_up'
                    ? 'Top up'
                    : (typeRaw == 'ride_payment' ? 'Ride payment' : typeRaw);
                final busId = '${m['busId'] ?? '-'}';
                final plate = _meta[busId]?.plate.isNotEmpty == true
                    ? _meta[busId]!.plate
                    : (_telemetry[busId]?.plateNumber ?? '-');
                final seat = '${(m['seatNo'] as num?)?.toInt() ?? '-'}';
                final delta = (m['deltaRwf'] as num?)?.toInt() ??
                    (m['amountDeltaRwf'] as num?)?.toInt() ??
                    0;
                final ts = m['createdAt'] as Timestamp?;
                final date = ts == null ? '-' : _formatTsForSearch(ts);
                return [type, busId, plate, seat, 'RWF $delta', date];
              }).toList(),
            ),
          ],
        ),
      );

      final bytes = await pdf.save();
      await Printing.sharePdf(bytes: bytes, filename: file);
      if (!mounted) return;
      _showBookingToast('PDF report generated.', success: true);
    } catch (e) {
      if (!mounted) return;
      _showBookingToast('PDF export failed: $e', success: false);
    }
  }

  String _timeAgo(Timestamp? ts) {
    if (ts == null) return 'now';
    final d = DateTime.now().difference(ts.toDate());
    if (d.inSeconds < 60) return '${d.inSeconds}s ago';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  Widget _fChip(String l, bool s, VoidCallback t) => InkWell(
        onTap: t,
        borderRadius: BorderRadius.circular(99),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
              color: s ? const Color(0xFF3B82F6) : Colors.white10,
              borderRadius: BorderRadius.circular(99)),
          child: Text(l,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600)),
        ),
      );

  Widget _statusCard() {
    if (_bookState == _BookState.idle ||
        _bookState == _BookState.selectingRoute ||
        _bookState == _BookState.booked ||
        _bookState == _BookState.failed) {
      return const SizedBox.shrink();
    }
    final t = switch (_bookState) {
      _BookState.booking => 'Booking seat...',
      _BookState.booked => 'Seat reserved. Waiting for tap on bus.',
      _BookState.paid => 'Paid. Ride confirmed.',
      _BookState.expired => 'Booking expired.',
      _BookState.failed => 'Booking failed.',
      _ => '',
    };
    final accent = switch (_bookState) {
      _BookState.booking => const Color(0xFF38BDF8),
      _BookState.booked => const Color(0xFF22C55E),
      _BookState.paid => const Color(0xFF10B981),
      _BookState.expired => const Color(0xFFF59E0B),
      _BookState.failed => const Color(0xFFEF4444),
      _ => const Color(0xFF38BDF8),
    };
    final icon = switch (_bookState) {
      _BookState.booking => Icons.sync_rounded,
      _BookState.booked => Icons.event_seat_rounded,
      _BookState.paid => Icons.verified_rounded,
      _BookState.expired => Icons.timelapse_rounded,
      _BookState.failed => Icons.error_outline_rounded,
      _ => Icons.info_outline_rounded,
    };
    return Positioned(
      left: 12,
      right: 12,
      bottom: 86,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xEE0B1220),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: accent.withValues(alpha: 0.7)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: accent, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  t,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          if (_session != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Text(
                      'Bus ${_session!.busId}',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Text(
                      'Seats ${_session!.seats.join(', ')}',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (_bookErr != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _bookErr!,
                style: const TextStyle(
                  color: Color(0xFFFCA5A5),
                  fontSize: 12,
                ),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _mapPausedPanel() {
    final list = _buses.take(10).toList();
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0B1220), Color(0xFF111827)],
        ),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: list.isEmpty
                ? Center(
                    child: Text(
                      _routeId == null
                          ? 'Select a direction to see available buses.'
                          : 'No live buses on this direction right now.',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 90, 12, 110),
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final b = list[i];
                      return ListTile(
                        tileColor: const Color(0x44111827),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: const BorderSide(color: Colors.white12),
                        ),
                        onTap: () => _showBus(b),
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFF3B82F6),
                          child: Text(
                            _short(b.name),
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                        title: Text(
                          b.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        subtitle: Text(
                          '${b.plate} - ${_eta(b)}',
                          style: const TextStyle(color: Colors.white70),
                        ),
                        trailing: Text(
                          '${_availableSeatsForBus(b)}/${b.seats} free',
                          style: TextStyle(
                            color: _seatColor(_availableSeatsForBus(b)),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Center(
            child: IgnorePointer(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 20),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xCC0F172A),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0x663B82F6)),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x55000000),
                      blurRadius: 18,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: const Row(
                  children: [
                    Icon(Icons.map_outlined, color: Color(0xFF93C5FD)),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Map is temporarily paused to avoid billing. Live buses, filters, cards, and booking still work.',
                        style: TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final route = _selectedRoute;
    final selectedSegment = _selectedSegment;
    final segments =
        route == null ? const <_SegmentOption>[] : _segmentsForRoute(route);
    final bookableSegments = route == null
        ? const <_SegmentOption>[]
        : _bookableSegmentsForRoute(route);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Msafiri'),
        actions: [
          if (!widget.embeddedInShell)
            IconButton(
              tooltip: 'Sign out',
              onPressed: () async {
                await FirebaseAuth.instance.signOut();
                if (!context.mounted) return;
                context.go(AppRoutes.login);
              },
              icon: const Icon(Icons.logout_rounded),
            ),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _fs
                .collection('user_notifications')
                .where(
                  'userId',
                  isEqualTo: FirebaseAuth.instance.currentUser?.uid ?? '',
                )
                .limit(25)
                .snapshots(),
            builder: (context, snap) {
              final unreadCount = snap.hasData
                  ? snap.data!.docs
                      .where((d) => d.data()['read'] != true)
                      .length
                  : 0;
              return IconButton(
                tooltip: 'Notifications',
                onPressed: _openNotifications,
                icon: Badge(
                  isLabelVisible: unreadCount > 0,
                  label: Text(unreadCount > 99 ? '99+' : '$unreadCount'),
                  child: const Icon(Icons.notifications_rounded),
                ),
              );
            },
          ),
          PopupMenuButton<_ProfileAction>(
            tooltip: 'Account',
            onSelected: _handleProfileMenuAction,
            icon: const Icon(Icons.person_rounded),
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _ProfileAction.profile,
                child: Row(
                  children: [
                    Icon(Icons.person_outline_rounded, size: 18),
                    SizedBox(width: 10),
                    Text('Profile'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: _ProfileAction.logout,
                child: Row(
                  children: [
                    Icon(
                      Icons.logout_rounded,
                      size: 18,
                      color: Color(0xFFEF4444),
                    ),
                    SizedBox(width: 10),
                    Text(
                      'Logout',
                      style: TextStyle(
                        color: Color(0xFFEF4444),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Stack(children: [
        if (_mapsPaused)
          _mapPausedPanel()
        else
          GoogleMap(
            initialCameraPosition:
                CameraPosition(target: _mapCenter, zoom: _zoom),
            mapType: _mapType,
            myLocationEnabled: false,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            style: _mapDark ? _darkMapStyle : null,
            markers: _markers,
            onMapCreated: (c) => _map = c,
            onCameraMove: (p) => _zoom = p.zoom,
          ),
        Positioned(
          top: 16,
          left: 12,
          right: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
                color: const Color(0xE610172A),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12)),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _routeId,
                          isExpanded: true,
                          dropdownColor: const Color(0xFF0F172A),
                          hint: const Row(
                            children: [
                              Icon(Icons.alt_route_rounded,
                                  size: 14, color: Colors.white70),
                              SizedBox(width: 6),
                              Text('Direction',
                                  style: TextStyle(color: Colors.white70)),
                            ],
                          ),
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.w600),
                          iconEnabledColor: Colors.white70,
                          items: _routes.map((r) {
                            final isForward =
                                r.directionLabel.toLowerCase() == 'forward';
                            final lockedCount = _segmentsForRoute(r).length -
                                _bookableSegmentsForRoute(r).length;
                            final lockLabel =
                                '${_segmentsForRoute(r).length} stop(s) ${lockedCount > 0 ? '$lockedCount Locked' : 'Open'}';
                            final arrow = isForward ? '→' : '←';
                            return DropdownMenuItem(
                              value: r.id,
                              child: Text(
                                '$arrow ${r.corridorName} | $lockLabel',
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          }).toList(),
                          onChanged: (v) {
                            setState(() {
                              _routeId = v;
                              _syncSegmentSelectionForRoute(_selectedRoute);
                            });
                            _scheduleMarkerRebuild(
                                delay: const Duration(milliseconds: 80));
                          },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.account_balance_wallet_rounded,
                            size: 14, color: Color(0xFF93C5FD)),
                        const SizedBox(width: 6),
                        Text(
                          'RWF ${_myCards.isEmpty ? 0 : _myCards.firstWhere((c) => c.id == (_selectedCardId ?? _myCards.first.id), orElse: () => _myCards.first).balance}',
                          style: const TextStyle(
                            color: Color(0xFF93C5FD),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (route != null && segments.isNotEmpty) ...[
                const SizedBox(height: 8),
                if (bookableSegments.isEmpty)
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'No fare for this corridor direction yet.',
                      style: TextStyle(
                        color: Color(0xFFFCA5A5),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                else
                  DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: selectedSegment == null
                          ? null
                          : '${selectedSegment.fromIndex}_${selectedSegment.toIndex}',
                      isExpanded: true,
                      dropdownColor: const Color(0xFF0F172A),
                      hint: const Text('Select stop chunk',
                          style: TextStyle(color: Colors.white70)),
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w600),
                      iconEnabledColor: Colors.white70,
                      items: bookableSegments
                          .map(
                            (s) => DropdownMenuItem(
                              value: '${s.fromIndex}_${s.toIndex}',
                              child: Text(
                                '🚌 ${s.fromName} → ${s.toName} | RWF ${_fareForSegment(route, s)}',
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v == null) return;
                        final parts = v.split('_');
                        if (parts.length != 2) return;
                        final from = int.tryParse(parts[0]);
                        final to = int.tryParse(parts[1]);
                        if (from == null || to == null) return;
                        setState(() {
                          _originStopIndex = from;
                          _destinationStopIndex = to;
                        });
                      },
                    ),
                  ),
              ],
            ]),
          ),
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 10,
          child: SafeArea(
            top: false,
            child: Center(
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  InkWell(
                    onTap: _openMyCards,
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                          color: const Color(0xE610172A),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white12)),
                      child:
                          const Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.credit_card_rounded,
                            size: 14, color: Color(0xFF93C5FD)),
                        SizedBox(width: 8),
                        Text('My Cards',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600)),
                      ]),
                    ),
                  ),
                  InkWell(
                    onTap: _openLive,
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                          color: const Color(0xE610172A),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white12)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.radio_button_checked,
                            size: 10, color: Color(0xFF22C55E)),
                        const SizedBox(width: 8),
                        Text('Live buses: ${_buses.length}',
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600)),
                      ]),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        _statusCard(),
        if (!_mapsPaused)
          Positioned(
            right: 12,
            bottom: 64,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              _mapBtn(_mapTypeIcon(), _cycleMapType),
              const SizedBox(height: 8),
              _mapBtn(
                _mapDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                () => setState(() => _mapDark = !_mapDark),
              ),
              const SizedBox(height: 8),
              _mapBtn(Icons.add_rounded, () => _zoomBy(0.8)),
              const SizedBox(height: 8),
              _mapBtn(Icons.remove_rounded, () => _zoomBy(-0.8)),
              const SizedBox(height: 8),
              _mapBtn(Icons.my_location_rounded, _locate),
            ]),
          ),
        if (_loading)
          const Positioned(
            top: 82,
            left: 0,
            right: 0,
            child: Center(
                child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2))),
          ),
        if (_actionLoading)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                color: const Color(0xB3000000),
                alignment: Alignment.center,
                child: Container(
                  width: 240,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xE610172A),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: Row(
                    children: [
                      const SpotlightLoader(size: 24),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _actionLoadingText,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        _internetBadge(),
      ]),
    );
  }

  Widget _mapBtn(IconData i, VoidCallback t) => Material(
        color: const Color(0xE610172A),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: t,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
                border: Border.all(color: Colors.white12),
                borderRadius: BorderRadius.circular(12)),
            child: Icon(i, color: Colors.white),
          ),
        ),
      );
}

class _Req {
  const _Req({required this.card, required this.seats});
  final String card;
  final List<int> seats;
}

class _BookSession {
  const _BookSession({
    required this.ids,
    required this.groupId,
    required this.busId,
    required this.seats,
    required this.card,
    required this.totalDeductRwf,
  });
  final List<String> ids;
  final String groupId;
  final String busId;
  final List<int> seats;
  final String card;
  final int totalDeductRwf;
}

class _Route {
  const _Route({
    required this.id,
    required this.corridorName,
    required this.directionLabel,
    required this.stopNames,
    required this.fare,
    required this.faresBySegment,
  });
  final String id;
  final String corridorName;
  final String directionLabel;
  final List<String> stopNames;
  final int fare;
  final Map<String, int> faresBySegment;

  String get from => stopNames.isEmpty ? '-' : stopNames.first;
  String get to => stopNames.isEmpty ? '-' : stopNames.last;
}

class _SegmentOption {
  const _SegmentOption({
    required this.fromIndex,
    required this.toIndex,
    required this.fromName,
    required this.toName,
  });

  final int fromIndex;
  final int toIndex;
  final String fromName;
  final String toName;
}

class _DirectionAssignment {
  const _DirectionAssignment({
    required this.busId,
    required this.directionId,
    required this.agencyId,
    required this.agencyName,
  });

  final String busId;
  final String directionId;
  final String agencyId;
  final String agencyName;
}

class _SeatLock {
  const _SeatLock({
    required this.busId,
    required this.seatNo,
    required this.directionId,
    required this.originStopIndex,
    required this.destinationStopIndex,
    required this.active,
  });

  final String busId;
  final int seatNo;
  final String directionId;
  final int originStopIndex;
  final int destinationStopIndex;
  final bool active;
}

class _Meta {
  const _Meta({
    required this.id,
    required this.routeId,
    required this.routeIds,
    required this.plate,
    required this.agency,
    required this.seats,
    required this.active,
  });
  final String id;
  final String routeId;
  final List<String> routeIds;
  final String plate;
  final String agency;
  final int? seats;
  final bool active;
}

class _CardInfo {
  const _CardInfo({
    required this.id,
    required this.balance,
    required this.active,
    required this.ownerName,
  });

  final String id;
  final int balance;
  final bool active;
  final String ownerName;
}

class _Live {
  const _Live({
    required this.id,
    required this.pos,
    required this.speed,
    required this.sits,
    required this.agencyName,
    required this.plateNumber,
  });
  final String id;
  final LatLng pos;
  final double? speed;
  final int? sits;
  final String agencyName;
  final String plateNumber;
}

class _Bus {
  const _Bus({required this.live, required this.meta});
  final _Live live;
  final _Meta? meta;
  String get name {
    if ((meta?.agency.isNotEmpty ?? false)) return meta!.agency;
    if (live.agencyName.isNotEmpty) return live.agencyName;
    return live.id;
  }

  String get plate {
    if ((meta?.plate.isNotEmpty ?? false)) return meta!.plate;
    if (live.plateNumber.isNotEmpty) return live.plateNumber;
    return 'No plate';
  }

  int get seats => (meta?.seats ?? live.sits ?? 0).clamp(0, 999);
}

const String _darkMapStyle = '''[
  {"elementType":"geometry","stylers":[{"color":"#0f172a"}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#94a3b8"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#0f172a"}]},
  {"featureType":"road","elementType":"geometry","stylers":[{"color":"#1f2937"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#0b4a6f"}]}
]''';


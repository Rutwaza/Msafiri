import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:spotlight_traffic_app/core/constants/app_constants.dart';
import 'package:spotlight_traffic_app/core/constants/realtime_db_contract.dart';
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
enum _ProfileAction { profile, settings, logout }

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
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _bookingSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _myCardsSub;

  final _meta = <String, _Meta>{};
  final _telemetry = <String, _Live>{};
  List<_Route> _routes = [];
  Set<Marker> _markers = {};

  LatLng _mapCenter = _center;
  LatLng? _me;
  DateTime? _lastUpdate;
  String? _routeId;
  double _zoom = 13.5;
  bool _dark = true;
  bool _loading = true;
  bool _connected = false;
  TrafficUserProfile? _profile;
  int _token = 0;
  _BookState _bookState = _BookState.selectingRoute;
  String? _bookErr;
  _BookSession? _session;
  final _myCards = <_CardInfo>[];
  String? _selectedCardId;
  bool _didInitialBusFocus = false;
  bool get _mapsPaused => AppConstants.pauseGoogleMaps;

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _locate();
    _listenTelemetry();
    _listenMeta();
    _listenRoutes();
    _listenMyCards();
  }

  @override
  void dispose() {
    _telemetrySub?.cancel();
    _metaSub?.cancel();
    _routesSub?.cancel();
    _bookingSub?.cancel();
    _myCardsSub?.cancel();
    _map?.dispose();
    super.dispose();
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
        _connected = true;
        _loading = false;
        _lastUpdate = DateTime.now();
      });
      unawaited(_buildMarkers());
    }, onError: (_) {
      if (!mounted) return;
      setState(() {
        _connected = false;
        _loading = false;
      });
    });
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
          active: m['active'] == true,
        );
      }
      unawaited(_buildMarkers());
    });
  }

  void _listenRoutes() {
    _routesSub = _fs
        .collection('routes')
        .where('active', isEqualTo: true)
        .snapshots()
        .listen((s) {
      final r = s.docs
          .map((d) => _Route(
              id: d.id,
              from: '${d['origin']}',
              to: '${d['destination']}',
              fare: (d['fareRwf'] as num?)?.toInt() ?? 0))
          .toList();
      if (!mounted) return;
      setState(() {
        _routes = r;
        if (_routeId == null && r.isNotEmpty) {
          _routeId = r.first.id;
          _bookState = _BookState.idle;
        }
      });
      unawaited(_buildMarkers());
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
      final cards = s.docs
          .map((d) => _CardInfo(
                id: d.id,
                balance: (d.data()['balanceRwf'] as num?)?.toInt() ?? 0,
                active: d.data()['active'] == true,
              ))
          .toList()
        ..sort((a, b) => b.balance.compareTo(a.balance));
      if (!mounted) return;
      setState(() {
        _myCards
          ..clear()
          ..addAll(cards);
        if (_selectedCardId == null ||
            !_myCards.any((c) => c.id == _selectedCardId)) {
          _selectedCardId = _myCards.isNotEmpty ? _myCards.first.id : null;
        }
      });
    });
  }

  List<_Bus> get _buses {
    final list = <_Bus>[];
    String selectedDirection = '';
    if (_routeId != null) {
      for (final r in _routes) {
        if (r.id == _routeId) {
          selectedDirection =
              '${r.from.trim().toLowerCase()}::${r.to.trim().toLowerCase()}';
          break;
        }
      }
    }
    _telemetry.forEach((id, t) {
      final m = _meta[id];
      if (m != null && !m.active) return;
      if (_routeId != null) {
        if (m == null) return;
        final candidateRouteIds = <String>{
          if (m.routeId.isNotEmpty) m.routeId,
          ...m.routeIds,
        };
        if (candidateRouteIds.isEmpty) return;
        bool supportsSelectedDirection = false;
        for (final routeId in candidateRouteIds) {
          _Route? busRoute;
          for (final r in _routes) {
            if (r.id == routeId) {
              busRoute = r;
              break;
            }
          }
          if (busRoute == null) continue;
          final busDirection =
              '${busRoute.from.trim().toLowerCase()}::${busRoute.to.trim().toLowerCase()}';
          if (selectedDirection.isEmpty || busDirection == selectedDirection) {
            supportsSelectedDirection = true;
            break;
          }
        }
        if (!supportsSelectedDirection) return;
      }
      list.add(_Bus(live: t, meta: m));
    });
    return list;
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
    final buses = _buses;
    final t = ++_token;
    final out = <Marker>{};
    for (final b in buses) {
      out.add(
        Marker(
          markerId: MarkerId(b.live.id),
          position: b.live.pos,
          anchor: const Offset(0.5, 0.86),
          icon: await _iconFor(b),
          onTap: () => _showBus(b),
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

  Future<BitmapDescriptor> _iconFor(_Bus b) async {
    final short = _short(b.meta?.agency ?? b.live.id);
    final seats = b.seats;
    final key = '${short}_$seats';
    if (_icons[key] != null) return _icons[key]!;
    const w = 150.0, h = 150.0, top = 10.0;
    const c = Offset(w / 2, h * 0.68);
    final rec = ui.PictureRecorder();
    final can = Canvas(rec);
    can.drawCircle(c, 28, Paint()..color = const Color(0x884B9FFF));
    can.drawCircle(c, 21, Paint()..color = const Color(0xFF3B82F6));
    final icon = TextPainter(textDirection: TextDirection.ltr)
      ..text = TextSpan(
        text: String.fromCharCode(Icons.directions_car_rounded.codePoint),
        style: TextStyle(
            fontSize: 24,
            fontFamily: Icons.directions_car_rounded.fontFamily,
            package: Icons.directions_car_rounded.fontPackage,
            color: Colors.white),
      )
      ..layout();
    icon.paint(can, Offset(c.dx - icon.width / 2, c.dy - icon.height / 2));
    final label = TextPainter(textDirection: TextDirection.ltr)
      ..text = TextSpan(
          text: '$short ($seats)',
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12))
      ..layout();
    final bw = label.width + 20;
    final left = (w - bw) / 2;
    can.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(left, top, bw, 28), const Radius.circular(14)),
      Paint()..color = const Color(0xFF111827),
    );
    label.paint(can, Offset(left + (bw - label.width) / 2, top + 7));
    can.drawLine(
        const Offset(w / 2, top + 28),
        Offset(c.dx, c.dy - 24),
        Paint()
          ..color = const Color(0xFF111827)
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round);
    final img = await rec.endRecording().toImage(w.toInt(), h.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    final out = BitmapDescriptor.bytes(bytes!.buffer.asUint8List());
    _icons[key] = out;
    return out;
  }

  String _short(String s) {
    final t = s.split('_').first.replaceAll(RegExp(r'[^A-Za-z]'), '');
    if (t.isEmpty) return '??';
    return t.length < 2
        ? t.toUpperCase()
        : '${t[0].toUpperCase()}${t[1].toLowerCase()}';
  }

  int _i(Object? v) => (v is num) ? v.toInt() : int.tryParse('$v') ?? 0;
  double? _toDouble(Object? v) =>
      (v is num) ? v.toDouble() : double.tryParse('$v');
  String _updatedText() {
    if (_lastUpdate == null) return 'No updates';
    final d = DateTime.now().difference(_lastUpdate!);
    if (d.inSeconds < 60) return '${d.inSeconds}s ago';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    return '${d.inHours}h ago';
  }

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

  Future<void> _handleProfileMenuAction(_ProfileAction action) async {
    switch (action) {
      case _ProfileAction.profile:
        final user = FirebaseAuth.instance.currentUser;
        final role = _profile == null
            ? 'unknown'
            : TrafficUserProfile.roleToString(_profile!.role);
        if (!mounted) return;
        await showModalBottomSheet<void>(
          context: context,
          backgroundColor: const Color(0xFF0F172A),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          builder: (ctx) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Profile',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text('Email: ${user?.email ?? '-'}'),
                  Text('UID: ${user?.uid ?? '-'}'),
                  Text('Role: $role'),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          ),
        );
        break;
      case _ProfileAction.settings:
        _showBookingToast('Settings page coming next.', success: true);
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

  Future<void> _book(_Bus b) async {
    if (_routeId == null) {
      setState(() => _bookState = _BookState.selectingRoute);
      _showBookingToast('Select a direction first', success: false);
      return;
    }
    final activeCards = _myCards.where((c) => c.active).toList();
    String selectedCard = _selectedCardId ?? '';
    if (activeCards.isNotEmpty && selectedCard.isEmpty) {
      selectedCard = activeCards.first.id;
    }
    String manualCard = '';
    String seatText = '';
    bool useOtherCard = false;
    final req = await showModalBottomSheet<_Req>(
      context: context,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setM) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Book Seat',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                if (activeCards.isNotEmpty) ...[
                  DropdownButtonFormField<String>(
                    initialValue: selectedCard.isEmpty
                        ? activeCards.first.id
                        : selectedCard,
                    dropdownColor: const Color(0xFF0F172A),
                    decoration: const InputDecoration(
                      labelText: 'Select card',
                      labelStyle: TextStyle(color: Colors.white70),
                    ),
                    items: activeCards
                        .map(
                          (c) => DropdownMenuItem<String>(
                            value: c.id,
                            child: Text(
                              '${c.id} - RWF ${c.balance}',
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setM(() => selectedCard = v ?? ''),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => setM(() => useOtherCard = !useOtherCard),
                      icon: Icon(
                        useOtherCard
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_unchecked_rounded,
                        size: 18,
                        color: const Color(0xFF93C5FD),
                      ),
                      label: Text(
                        useOtherCard ? 'Using other card' : 'Use other card',
                        style: const TextStyle(color: Color(0xFFBFDBFE)),
                      ),
                    ),
                  ),
                ],
                if (activeCards.isEmpty || useOtherCard) ...[
                  TextField(
                    style: const TextStyle(color: Colors.white),
                    onChanged: (v) => setM(() => manualCard = v),
                    decoration: const InputDecoration(
                      labelText: 'Other card ID',
                      labelStyle: TextStyle(color: Colors.white70),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                TextField(
                  style: const TextStyle(color: Colors.white),
                  keyboardType: TextInputType.number,
                  onChanged: (v) => setM(() => seatText = v),
                  decoration: const InputDecoration(
                    labelText: 'Seat #',
                    labelStyle: TextStyle(color: Colors.white70),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      final s = int.tryParse(seatText.trim());
                      final cardId = ((_myCards.isNotEmpty && !useOtherCard)
                              ? selectedCard
                              : manualCard)
                          .trim();
                      if (s == null || s <= 0 || cardId.isEmpty) return;
                      FocusManager.instance.primaryFocus?.unfocus();
                      Navigator.pop(ctx, _Req(card: cardId, seat: s));
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
    if (!mounted) return;
    setState(() {
      _bookState = _BookState.booking;
      _bookErr = null;
    });
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw Exception('Sign in required before booking.');
      }
      // Force-refresh ID token so callable functions always receive auth.
      await user.getIdToken(true);
      final idem =
          '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(99999)}';
      final payload = {
        'uid': user.uid,
        'busId': b.live.id,
        'routeId': _routeId,
        'cardId': req.card,
        'seatNo': req.seat,
        'idempotencyKey': idem,
      };
      dynamic res;
      try {
        final fn = _fx.httpsCallable('bookSeat');
        res = await fn.call(payload);
      } on FirebaseFunctionsException catch (e) {
        // Some projects can have Cloud Run invoker restrictions on v2 callable.
        // Retry through v1 callable fallback before surfacing the error.
        if (e.code != 'unauthenticated') rethrow;
        final fallbackFn = _fx.httpsCallable('bookSeatV1');
        res = await fallbackFn.call(payload);
      }
      final data = Map<String, dynamic>.from(res.data as Map);
      final id = '${data['bookingId'] ?? ''}';
      if (id.isEmpty) throw Exception('booking id missing');
      _bookingSub?.cancel();
      _bookingSub = _fs.collection('bookings').doc(id).snapshots().listen((s) {
        final status = '${s.data()?['status'] ?? ''}';
        final previous = _bookState;
        if (!mounted) return;
        setState(() {
          if (status == 'paid') _bookState = _BookState.paid;
          if (status == 'expired') _bookState = _BookState.expired;
          if (status == 'booked') _bookState = _BookState.booked;
        });
        if (status == 'paid' && previous != _BookState.paid) {
          _showBookingToast('Payment successful. Ride confirmed',
              success: true);
        } else if (status == 'expired' && previous != _BookState.expired) {
          _showBookingToast('Booking expired. Please book again',
              success: false);
        }
      });
      setState(() {
        _session = _BookSession(
            id: id, busId: b.live.id, seat: req.seat, card: req.card);
        _bookState = _BookState.booked;
        _selectedCardId = req.card;
      });
      _showBookingToast('Seat booked. Waiting for tap on bus', success: true);
    } catch (e) {
      final friendly = _friendlyBookingError(e);
      setState(() {
        _bookState = _BookState.failed;
        _bookErr = friendly;
      });
      _showBookingToast(friendly, success: false);
    }
  }

  void _showBus(_Bus b) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => SafeArea(
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
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 18)),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  _pill(Icons.pin, b.plate),
                  _pill(Icons.event_seat_rounded, '${b.seats} seats',
                      c: _seatColor(b.seats)),
                  _pill(Icons.schedule, _eta(b)),
                ]),
                const SizedBox(height: 14),
                SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                        onPressed: () => _book(b),
                        icon: const Icon(Icons.event_seat_rounded),
                        label: const Text('Book seat'))),
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
                            _zoom = 16.2;
                            await _map?.animateCamera(
                                CameraUpdate.newLatLngZoom(b.live.pos, _zoom));
                            if (mounted) _showBus(b);
                          },
                          leading: CircleAvatar(
                              backgroundColor: const Color(0xFF3B82F6),
                              child: Text(_short(b.name),
                                  style: const TextStyle(color: Colors.white))),
                          title: Text(b.name,
                              style: const TextStyle(color: Colors.white)),
                          subtitle: Text(
                              '${_kmd(b).toStringAsFixed(1)} km • ${_eta(b)}',
                              style: const TextStyle(color: Colors.white70)),
                          trailing: Text('${b.seats} seats',
                              style: TextStyle(
                                  color: _seatColor(b.seats),
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
                    height: 88,
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
                              return InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: () {
                                  setState(() => _selectedCardId = card.id);
                                },
                                child: Container(
                                  width: 220,
                                  padding: const EdgeInsets.all(12),
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
                                      Text(
                                        card.id,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const Spacer(),
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
                                      const SizedBox(height: 2),
                                      Text(
                                        'RWF ${card.balance}',
                                        style: const TextStyle(
                                          color: Color(0xFF93C5FD),
                                          fontWeight: FontWeight.w800,
                                          fontSize: 18,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 8),
                  if (_myCards.isNotEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          final card = _myCards.firstWhere(
                            (c) =>
                                c.id == (_selectedCardId ?? _myCards.first.id),
                            orElse: () => _myCards.first,
                          );
                          _requestCardStatusChange(
                            cardId: card.id,
                            active: !card.active,
                          );
                        },
                        icon: const Icon(Icons.content_cut_rounded),
                        label: Text(
                          (() {
                            final card = _myCards.firstWhere(
                              (c) =>
                                  c.id ==
                                  (_selectedCardId ?? _myCards.first.id),
                              orElse: () => _myCards.first,
                            );
                            return card.active
                                ? 'Request Cut Card'
                                : 'Request Reactivation';
                          })(),
                        ),
                      ),
                    ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: _fs
                          .collection('card_transactions')
                          .where('userId', isEqualTo: uid)
                          .orderBy('createdAt', descending: true)
                          .limit(200)
                          .snapshots(),
                      builder: (context, snap) {
                        if (!snap.hasData) {
                          return const Center(
                              child: CircularProgressIndicator(strokeWidth: 2));
                        }
                        var docs = snap.data!.docs;
                        if (_selectedCardId != null) {
                          docs = docs
                              .where((d) =>
                                  '${d.data()['cardId'] ?? ''}' ==
                                  _selectedCardId)
                              .toList();
                        }
                        if (docs.isEmpty) {
                          return const Center(
                            child: Text(
                              'No transactions yet for this card.',
                              style: TextStyle(color: Colors.white70),
                            ),
                          );
                        }
                        return ListView.builder(
                          controller: c,
                          itemCount: docs.length,
                          itemBuilder: (_, i) {
                            final m = docs[i].data();
                            final type = '${m['type'] ?? ''}';
                            final delta =
                                (m['amountDeltaRwf'] as num?)?.toInt() ?? 0;
                            final bal =
                                (m['balanceAfterRwf'] as num?)?.toInt() ?? 0;
                            final ts = m['createdAt'] as Timestamp?;
                            final bookingUser =
                                '${m['bookingUserName'] ?? m['userName'] ?? m['userId'] ?? ''}'
                                    .trim();
                            final cardOwner =
                                '${m['cardOwnerName'] ?? m['cardOwnerUid'] ?? ''}'
                                    .trim();
                            final external = m['usedExternalCard'] == true;
                            final color = type == 'TOPUP'
                                ? const Color(0xFF22C55E)
                                : (type == 'PAID'
                                    ? const Color(0xFFEF4444)
                                    : const Color(0xFF3B82F6));
                            final deltaText = delta > 0 ? '+$delta' : '$delta';
                            return ListTile(
                              dense: true,
                              leading: CircleAvatar(
                                radius: 16,
                                backgroundColor: color.withValues(alpha: 0.18),
                                child: Icon(
                                  type == 'TOPUP'
                                      ? Icons.arrow_downward_rounded
                                      : (type == 'PAID'
                                          ? Icons.remove_rounded
                                          : Icons.bookmark_added_rounded),
                                  color: color,
                                  size: 18,
                                ),
                              ),
                              title: Text(
                                external ? '$type (Other Card)' : type,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700),
                              ),
                              subtitle: Text(
                                '${m['note'] ?? ''}\n'
                                '${bookingUser.isEmpty ? '' : 'By: $bookingUser'}'
                                '${cardOwner.isEmpty ? '' : ' • Card owner: $cardOwner'}\n'
                                '${_timeAgo(ts)}',
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 12),
                              ),
                              isThreeLine: true,
                              trailing: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    'RWF $deltaText',
                                    style: TextStyle(
                                        color: color,
                                        fontWeight: FontWeight.w800),
                                  ),
                                  Text(
                                    'Bal: $bal',
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 11),
                                  ),
                                ],
                              ),
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

  Future<void> _requestCardStatusChange({
    required String cardId,
    required bool active,
  }) async {
    try {
      final callable = _fx.httpsCallable('requestCardStatusChange');
      await callable.call({
        'cardId': cardId,
        'active': active,
      });
      if (!mounted) return;
      _showBookingToast(
        active ? 'Reactivation request sent' : 'Cut-card request sent',
        success: true,
      );
    } catch (_) {
      if (!mounted) return;
      _showBookingToast('Could not submit card request', success: false);
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
        _bookState == _BookState.selectingRoute) {
      return const SizedBox.shrink();
    }
    final t = switch (_bookState) {
      _BookState.booking => 'Booking seat...',
      _BookState.booked => 'Seat booked. Waiting for tap on bus.',
      _BookState.paid => 'Paid. Ride confirmed.',
      _BookState.expired => 'Booking expired.',
      _BookState.failed => 'Booking failed.',
      _ => '',
    };
    return Positioned(
      left: 12,
      right: 12,
      bottom: 86,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
            color: const Color(0xE610172A),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white24)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w700)),
          if (_session != null)
            Text(
                'Bus ${_session!.busId} • Seat ${_session!.seat} • ${_session!.id.substring(0, 6)}',
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
          if (_bookErr != null)
            Text(_bookErr!,
                style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 12)),
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
                ? const Center(
                    child: Text(
                      'No live buses right now.',
                      style: TextStyle(color: Colors.white70),
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
                          '${b.seats} seats',
                          style: TextStyle(
                            color: _seatColor(b.seats),
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
    _Route? route;
    for (final r in _routes) {
      if (r.id == _routeId) {
        route = r;
        break;
      }
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(route == null
            ? 'Traffic Management'
            : '${route.from} → ${route.to}'),
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
          PopupMenuButton<_ProfileAction>(
            tooltip: 'Account',
            onSelected: _handleProfileMenuAction,
            icon: const Icon(Icons.person_rounded),
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _ProfileAction.profile,
                child: Text('Profile'),
              ),
              PopupMenuItem(
                value: _ProfileAction.settings,
                child: Text('Settings'),
              ),
              PopupMenuItem(
                value: _ProfileAction.logout,
                child: Text('Logout'),
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
            myLocationEnabled: false,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            style: _dark ? _darkMapStyle : null,
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
                children: [
                  Expanded(
                    child: Text(
                        '${_connected ? 'Connected' : 'Disconnected'} • ${_lastUpdate == null ? 'No updates' : _updatedText()} • Live ${_buses.length}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ),
                  IconButton(
                    tooltip: 'Toggle map theme',
                    onPressed: () => setState(() => _dark = !_dark),
                    iconSize: 18,
                    splashRadius: 18,
                    icon: Icon(
                      _dark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
              if (_myCards.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'Card ${_selectedCardId ?? _myCards.first.id} • Balance RWF ${_myCards.firstWhere((c) => c.id == (_selectedCardId ?? _myCards.first.id), orElse: () => _myCards.first).balance}',
                  style: const TextStyle(
                      color: Color(0xFF93C5FD),
                      fontSize: 12,
                      fontWeight: FontWeight.w700),
                ),
              ],
              const SizedBox(height: 8),
              DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _routeId,
                  isExpanded: true,
                  dropdownColor: const Color(0xFF0F172A),
                  hint: const Text('Select route',
                      style: TextStyle(color: Colors.white70)),
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600),
                  iconEnabledColor: Colors.white70,
                  items: _routes
                      .map((r) => DropdownMenuItem(
                          value: r.id,
                          child: Text('${r.from} → ${r.to} (RWF ${r.fare})')))
                      .toList(),
                  onChanged: (v) {
                    setState(() {
                      _routeId = v;
                      _bookState = v == null
                          ? _BookState.selectingRoute
                          : _BookState.idle;
                    });
                    unawaited(_buildMarkers());
                  },
                ),
              ),
            ]),
          ),
        ),
        Positioned(
          left: 12,
          bottom: 22,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                onTap: _openMyCards,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                      color: const Color(0xE610172A),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white12)),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.credit_card_rounded,
                        size: 14, color: Color(0xFF93C5FD)),
                    SizedBox(width: 8),
                    Text('My Cards',
                        style: TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
              const SizedBox(height: 8),
              InkWell(
                onTap: _openLive,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                            color: Colors.white, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
            ],
          ),
        ),
        _statusCard(),
        if (!_mapsPaused)
          Positioned(
            right: 12,
            bottom: 22,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
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
  const _Req({required this.card, required this.seat});
  final String card;
  final int seat;
}

class _BookSession {
  const _BookSession(
      {required this.id,
      required this.busId,
      required this.seat,
      required this.card});
  final String id;
  final String busId;
  final int seat;
  final String card;
}

class _Route {
  const _Route(
      {required this.id,
      required this.from,
      required this.to,
      required this.fare});
  final String id;
  final String from;
  final String to;
  final int fare;
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
  });

  final String id;
  final int balance;
  final bool active;
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

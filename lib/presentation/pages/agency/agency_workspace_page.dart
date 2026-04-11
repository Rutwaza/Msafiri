import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:spotlight_traffic_app/core/constants/realtime_db_contract.dart';
import 'package:spotlight_traffic_app/core/widgets/spotlight_toast.dart';

class AgencyWorkspacePage extends StatelessWidget {
  const AgencyWorkspacePage({
    super.key,
    required this.agencyId,
    required this.agencyName,
  });

  final String agencyId;
  final String agencyName;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(agencyName),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Overview'),
              Tab(text: 'Members'),
              Tab(text: 'Fleet'),
              Tab(text: 'Settings'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            Center(child: Text('Overview for $agencyId')),
            const Center(child: Text('Members management coming next.')),
            _FleetTab(agencyId: agencyId, agencyName: agencyName),
            const Center(child: Text('Agency settings coming next.')),
          ],
        ),
      ),
    );
  }
}

class _FleetTab extends StatefulWidget {
  const _FleetTab({required this.agencyId, required this.agencyName});

  final String agencyId;
  final String agencyName;

  @override
  State<_FleetTab> createState() => _FleetTabState();
}

class _FleetTabState extends State<_FleetTab> {
  final _fs = FirebaseFirestore.instance;
  final _fx = FirebaseFunctions.instanceFor(region: 'us-central1');
  final _auth = FirebaseAuth.instance;

  String _norm(String? v) => (v ?? '').trim().toLowerCase();

  double? _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse('$v');
  }

  int? _toInt(dynamic v) {
    if (v is num) return v.toInt();
    return int.tryParse('$v');
  }

  Map<String, dynamic>? _latestPoint(Map<String, dynamic> raw) {
    final latest = raw[RtdbContract.latestKey];
    if (latest is Map) return Map<String, dynamic>.from(latest);

    Map<String, dynamic>? best;
    int? bestTs;
    for (final entry in raw.entries) {
      final key = entry.key;
      final val = entry.value;
      if (!key.startsWith('-T') || val is! Map) continue;
      final m = Map<String, dynamic>.from(val);
      final ts = _toInt(m['ts']) ?? 0;
      if (best == null || ts > (bestTs ?? 0)) {
        best = m;
        bestTs = ts;
      }
    }
    return best;
  }

  Future<HttpsCallableResult<dynamic>> _callWithFreshAuth(
    String name,
    Map<String, dynamic> payload,
  ) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw FirebaseFunctionsException(
        code: 'unauthenticated',
        message: 'Sign in required.',
      );
    }
    final idToken = await user.getIdToken(true);
    final callable = _fx.httpsCallable(name);
    return callable.call({...payload, 'idToken': idToken});
  }

  void _toast(String text, {bool success = false}) {
    if (!mounted) return;
    showSpotlightToast(
      context,
      text,
      success: success,
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 16),
    );
  }

  Future<void> _openAssignDirectionForm({
    required String busId,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> directions,
  }) async {
    if (directions.isEmpty) {
      _toast('No route directions available yet.');
      return;
    }
    String? directionId = directions.first.id;

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setM) => SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Assign Direction to $busId',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: directionId,
                  decoration: const InputDecoration(labelText: 'Direction'),
                  items: directions.map((d) {
                    final m = d.data();
                    final corridor = '${m['corridorName'] ?? 'Corridor'}';
                    final label = '${m['directionLabel'] ?? 'direction'}';
                    final stops = (m['stopNames'] as List<dynamic>? ?? const [])
                        .map((e) => '$e')
                        .join(' -> ');
                    return DropdownMenuItem(
                      value: d.id,
                      child: Text(
                        '$corridor ($label)\n$stops',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  }).toList(),
                  onChanged: (v) => setM(() => directionId = v),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: directionId == null
                        ? null
                        : () => Navigator.pop(ctx, true),
                    child: const Text('Assign'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (ok != true || directionId == null) return;
    try {
      await _callWithFreshAuth('assignBusDirectionV2', {
        'agencyId': widget.agencyId,
        'busId': busId,
        'directionId': directionId,
      });
      _toast('Direction assigned to $busId.', success: true);
    } catch (e) {
      _toast('Assign failed: $e');
    }
  }

  Future<void> _openSetFareForm({
    required QueryDocumentSnapshot<Map<String, dynamic>> directionDoc,
  }) async {
    final m = directionDoc.data();
    final stops = (m['stopNames'] as List<dynamic>? ?? const [])
        .map((e) => '$e')
        .where((e) => e.trim().isNotEmpty)
        .toList();
    if (stops.length < 2) {
      _toast('Direction has no valid stop chain.');
      return;
    }

    int fromIndex = 0;
    int toIndex = 1;
    String fareText = '';

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setM) {
          final toChoices = List<int>.generate(
            stops.length - (fromIndex + 1),
            (i) => fromIndex + 1 + i,
          );
          if (!toChoices.contains(toIndex)) {
            toIndex = toChoices.first;
          }
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Set Segment Fare (${m['corridorName'] ?? ''} - ${m['directionLabel'] ?? ''})',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<int>(
                    initialValue: fromIndex,
                    decoration: const InputDecoration(labelText: 'From stop'),
                    items: List.generate(stops.length - 1, (i) {
                      return DropdownMenuItem<int>(
                        value: i,
                        child: Text(stops[i]),
                      );
                    }),
                    onChanged: (v) {
                      if (v == null) return;
                      setM(() {
                        fromIndex = v;
                        if (toIndex <= fromIndex) {
                          toIndex = fromIndex + 1;
                        }
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int>(
                    initialValue: toIndex,
                    decoration: const InputDecoration(labelText: 'To stop'),
                    items: toChoices.map((i) {
                      return DropdownMenuItem<int>(
                        value: i,
                        child: Text(stops[i]),
                      );
                    }).toList(),
                    onChanged: (v) => setM(() => toIndex = v ?? toIndex),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    style: const TextStyle(color: Colors.white),
                    keyboardType: TextInputType.number,
                    onChanged: (v) => fareText = v,
                    decoration: const InputDecoration(labelText: 'Fare (RWF)'),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Save fare'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    if (ok != true) return;
    final fareRwf = int.tryParse(fareText.trim());
    if (fareRwf == null || fareRwf < 0) {
      _toast('Fare must be a valid positive number.');
      return;
    }

    try {
      await _callWithFreshAuth('setAgencyDirectionFareV2', {
        'agencyId': widget.agencyId,
        'directionId': directionDoc.id,
        'fromStopIndex': fromIndex,
        'toStopIndex': toIndex,
        'fareRwf': fareRwf,
      });
      _toast(
        'Fare saved: ${stops[fromIndex]} -> ${stops[toIndex]} = $fareRwf RWF',
        success: true,
      );
    } catch (e) {
      _toast('Fare save failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final rtdb = FirebaseDatabase.instanceFor(
      app: FirebaseDatabase.instance.app,
      databaseURL: RtdbContract.dbUrl,
    );

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _fs
          .collection('route_directions')
          .where('active', isEqualTo: true)
          .limit(250)
          .snapshots(),
      builder: (context, directionSnap) {
        if (directionSnap.hasError) {
          return Center(child: Text('Directions load failed: ${directionSnap.error}'));
        }
        if (!directionSnap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final directionDocs = directionSnap.data!.docs;
        final directionById = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{
          for (final d in directionDocs) d.id: d,
        };

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _fs
              .collection('bus_direction_assignments')
              .where('agencyId', isEqualTo: widget.agencyId)
              .where('active', isEqualTo: true)
              .limit(250)
              .snapshots(),
          builder: (context, assignSnap) {
            if (assignSnap.hasError) {
              return Center(child: Text('Assignments load failed: ${assignSnap.error}'));
            }
            if (!assignSnap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }

            final assignByBusId = <String, Map<String, dynamic>>{
              for (final d in assignSnap.data!.docs) d.id: d.data(),
            };

            return StreamBuilder<DatabaseEvent>(
              stream: rtdb.ref(RtdbContract.devicesPath).onValue,
              builder: (context, rtdbSnap) {
                if (rtdbSnap.hasError) {
                  return Center(child: Text('Fleet load failed: ${rtdbSnap.error}'));
                }
                if (!rtdbSnap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final root = rtdbSnap.data!.snapshot.value;
                if (root is! Map) {
                  return const Center(child: Text('No fleet data yet.'));
                }

                final buses = <Map<String, dynamic>>[];
                for (final e in root.entries) {
                  final busId = '${e.key}';
                  final val = e.value;
                  if (val is! Map) continue;
                  final m = Map<String, dynamic>.from(val);
                  final agency = '${m['agencyName'] ?? ''}';
                  if (_norm(agency) != _norm(widget.agencyName)) continue;
                  final latest = _latestPoint(m);
                  buses.add({
                    'id': busId,
                    'plateNumber': '${m['plateNumber'] ?? ''}',
                    'seats': _toInt(m['sits']),
                    'lat': latest == null ? null : _toDouble(latest['lat']),
                    'lng': latest == null ? null : _toDouble(latest['lng']),
                    'spd': latest == null ? null : _toDouble(latest['spd']),
                  });
                }

                if (buses.isEmpty) {
                  return Center(
                    child: Text('No buses found for "${widget.agencyName}" in realtime devices.'),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: buses.length,
                  itemBuilder: (context, i) {
                    final b = buses[i];
                    final busId = '${b['id']}';
                    final plate = '${b['plateNumber'] ?? ''}'.trim();
                    final seats = b['seats'];
                    final lat = b['lat'];
                    final lng = b['lng'];
                    final spd = b['spd'];

                    final assignment = assignByBusId[busId] ?? const <String, dynamic>{};
                    final directionId = '${assignment['directionId'] ?? ''}'.trim();
                    final directionDoc = directionById[directionId];
                    final direction = directionDoc?.data();
                    final corridor = '${direction?['corridorName'] ?? ''}'.trim();
                    final label = '${direction?['directionLabel'] ?? ''}'.trim();
                    final assignedText = directionId.isEmpty
                        ? 'Not assigned'
                        : '$corridor ($label)';

                    return Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: ListTile(
                        leading: const CircleAvatar(
                          child: Icon(Icons.directions_bus_rounded),
                        ),
                        title: Text(busId),
                        subtitle: Text(
                          'Plate: ${plate.isEmpty ? '-' : plate} - Seats: ${seats ?? '-'}\n'
                          'Pos: ${lat ?? '-'}, ${lng ?? '-'} - Speed: ${spd ?? '-'}\n'
                          'Direction: $assignedText',
                        ),
                        isThreeLine: true,
                        trailing: PopupMenuButton<String>(
                          onSelected: (value) {
                            if (value == 'assign') {
                              _openAssignDirectionForm(
                                busId: busId,
                                directions: directionDocs,
                              );
                              return;
                            }
                            if (directionDoc == null) {
                              _toast('Assign a direction first.');
                              return;
                            }
                            _openSetFareForm(directionDoc: directionDoc);
                          },
                          itemBuilder: (context) => const [
                            PopupMenuItem(
                              value: 'assign',
                              child: Text('Assign direction'),
                            ),
                            PopupMenuItem(
                              value: 'fare',
                              child: Text('Set segment fare'),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

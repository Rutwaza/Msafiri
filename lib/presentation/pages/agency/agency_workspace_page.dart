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
            _OverviewTab(agencyId: agencyId),
            _MembersTab(agencyId: agencyId),
            _FleetTab(agencyId: agencyId, agencyName: agencyName),
            const Center(child: Text('Agency settings coming next.')),
          ],
        ),
      ),
    );
  }
}

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({required this.agencyId});

  final String agencyId;

  String _rwf(num value) => 'RWF ${value.toInt()}';

  @override
  Widget build(BuildContext context) {
    final fs = FirebaseFirestore.instance;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Finance Overview (Agency Only)',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: fs
                      .collection('card_transactions')
                      .where('agencyId', isEqualTo: agencyId)
                      .where('type', isEqualTo: 'ride_payment')
                      .limit(5000)
                      .snapshots(),
                  builder: (context, snap) {
                    if (snap.hasError) return Text('${snap.error}');
                    if (!snap.hasData) {
                      return const LinearProgressIndicator(minHeight: 2);
                    }
                    final docs = snap.data!.docs;
                    final now = DateTime.now();
                    final startOfToday = DateTime(now.year, now.month, now.day);
                    int totalPaidRwf = 0;
                    int paidTodayRwf = 0;

                    for (final d in docs) {
                      final m = d.data();
                      final raw = (m['deltaRwf'] as num?)?.toInt() ??
                          (m['amountDeltaRwf'] as num?)?.toInt() ??
                          0;
                      final paid = raw < 0 ? -raw : raw;
                      if (paid <= 0) continue;
                      totalPaidRwf += paid;

                      final ts = m['createdAt'] as Timestamp?;
                      final at = ts?.toDate();
                      if (at != null && at.isAfter(startOfToday)) {
                        paidTodayRwf += paid;
                      }
                    }

                    final commissionRwf = (totalPaidRwf * 0.05).round();
                    final netAgencyRwf = totalPaidRwf - commissionRwf;
                    return Column(
                      children: [
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Total paid to agency'),
                          trailing: Text(
                            _rwf(totalPaidRwf),
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Today collection'),
                          trailing: Text(
                            _rwf(paidTodayRwf),
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Msafiri 5%'),
                          trailing: Text(
                            _rwf(commissionRwf),
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              color: Color(0xFFF59E0B),
                            ),
                          ),
                        ),
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Agency net'),
                          trailing: Text(
                            _rwf(netAgencyRwf),
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF22C55E),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Recent Bookings',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: fs
                      .collection('bookings')
                      .where('agencyId', isEqualTo: agencyId)
                      .orderBy('createdAt', descending: true)
                      .limit(30)
                      .snapshots(),
                  builder: (context, snap) {
                    if (snap.hasError) return Text('${snap.error}');
                    if (!snap.hasData) {
                      return const LinearProgressIndicator(minHeight: 2);
                    }
                    final docs = snap.data!.docs;
                    if (docs.isEmpty) return const Text('No bookings yet.');
                    return Column(
                      children: docs.take(6).map((d) {
                        final m = d.data();
                        final seat = '${m['seatNo'] ?? '-'}';
                        final bus = '${m['busId'] ?? '-'}';
                        final status = '${m['status'] ?? '-'}';
                        final from = '${m['originStopName'] ?? '-'}';
                        final to = '${m['destinationStopName'] ?? '-'}';
                        final fare = (m['fareRwf'] as num?)?.toInt() ?? 0;
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text('Bus $bus - Seat $seat - $status'),
                          subtitle: Text('$from -> $to - RWF $fare'),
                        );
                      }).toList(),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Recent Payments',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: fs
                      .collection('card_transactions')
                      .where('agencyId', isEqualTo: agencyId)
                      .orderBy('createdAt', descending: true)
                      .limit(30)
                      .snapshots(),
                  builder: (context, snap) {
                    if (snap.hasError) return Text('${snap.error}');
                    if (!snap.hasData) {
                      return const LinearProgressIndicator(minHeight: 2);
                    }
                    final docs = snap.data!.docs;
                    if (docs.isEmpty) return const Text('No payments yet.');
                    return Column(
                      children: docs.take(6).map((d) {
                        final m = d.data();
                        final type = '${m['type'] ?? '-'}';
                        final booking = '${m['bookingId'] ?? '-'}';
                        final delta = (m['deltaRwf'] as num?)?.toInt() ?? 0;
                        final bal = (m['balanceAfter'] as num?)?.toInt() ?? 0;
                        final seat = '${m['seatNo'] ?? '-'}';
                        final bus = '${m['busId'] ?? '-'}';
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text('$type - Bus $bus - Seat $seat'),
                          subtitle: Text(
                              'Booking: $booking\nDelta: RWF $delta - Balance: RWF $bal'),
                          isThreeLine: true,
                        );
                      }).toList(),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MembersTab extends StatefulWidget {
  const _MembersTab({required this.agencyId});

  final String agencyId;

  @override
  State<_MembersTab> createState() => _MembersTabState();
}

class _MembersTabState extends State<_MembersTab> {
  final _fs = FirebaseFirestore.instance;
  final _fx = FirebaseFunctions.instanceFor(region: 'us-central1');
  final _auth = FirebaseAuth.instance;
  bool _actionLoading = false;
  String _actionText = 'Processing request...';

  Future<T> _runWithLoader<T>(
    String message,
    Future<T> Function() action,
  ) async {
    if (mounted) {
      setState(() {
        _actionLoading = true;
        _actionText = message;
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

  Future<Map<String, String>?> _pickTrafficUser() async {
    final docs = await _fs.collection('traffic_users').limit(500).get();
    if (docs.docs.isEmpty) return null;
    if (!mounted) return null;

    final users = docs.docs.map((d) {
      final m = d.data();
      final email = '${m['email'] ?? ''}'.trim();
      final name =
          '${m['name'] ?? m['fullName'] ?? m['displayName'] ?? ''}'.trim();
      return {
        'id': d.id,
        'email': email,
        'name': name,
      };
    }).toList();

    return showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) {
        final searchCtrl = TextEditingController();
        String q = '';
        return StatefulBuilder(
          builder: (ctx, setD) {
            final filtered = users
                .where((u) {
                  final hay = '${u['name']} ${u['email']} ${u['id']}'
                      .toLowerCase();
                  return q.isEmpty || hay.contains(q);
                })
                .take(80)
                .toList();

            return AlertDialog(
              title: const Text('Find traffic user'),
              content: SizedBox(
                width: 520,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: searchCtrl,
                      onChanged: (v) => setD(() => q = v.trim().toLowerCase()),
                      decoration: const InputDecoration(
                        hintText: 'Search by name/email',
                        prefixIcon: Icon(Icons.search_rounded),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 320,
                      width: double.infinity,
                      child: filtered.isEmpty
                          ? const Center(child: Text('No users found'))
                          : ListView.builder(
                              itemCount: filtered.length,
                              itemBuilder: (ctx, i) {
                                final u = filtered[i];
                                final name =
                                    u['name']?.trim().isNotEmpty == true
                                        ? u['name']!
                                        : '(No name)';
                                final email =
                                    u['email']?.trim().isNotEmpty == true
                                        ? u['email']!
                                        : '(No email)';
                                return ListTile(
                                  dense: true,
                                  title: Text(name),
                                  subtitle: Text('$email\n${u['id']}'),
                                  isThreeLine: true,
                                  onTap: () => Navigator.of(ctx).pop(u),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Close'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _openAddMemberForm() async {
    String memberEmail = '';
    String memberUid = '';
    String selectedUserLabel = '';
    const roleOptions = [
      'agency_admin',
      'agency_staff',
      'dispatcher',
      'finance',
      'viewer',
    ];
    String role = roleOptions.first;

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setM) => SafeArea(
          child: SingleChildScrollView(
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
                  const Text(
                    'Add Agency Member',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final selected = await _pickTrafficUser();
                        if (!mounted || selected == null) return;
                        setM(() {
                          memberUid = (selected['id'] ?? '').trim();
                          memberEmail = (selected['email'] ?? '').trim();
                          selectedUserLabel =
                              '${selected['name'] ?? ''} (${selected['email'] ?? selected['id'] ?? ''})';
                        });
                      },
                      icon: const Icon(Icons.search_rounded),
                      label: const Text('Find registered user'),
                    ),
                  ),
                  if (selectedUserLabel.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        selectedUserLabel,
                        style: const TextStyle(
                          color: Color(0xFF93C5FD),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  TextField(
                    style: const TextStyle(color: Colors.white),
                    keyboardType: TextInputType.emailAddress,
                    onChanged: (v) => setM(() {
                      memberEmail = v;
                      if (v.trim().isNotEmpty) {
                        memberUid = '';
                      }
                    }),
                    decoration: const InputDecoration(
                      labelText: 'Member email',
                    ),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: role,
                    decoration: const InputDecoration(labelText: 'Role'),
                    items: roleOptions
                        .map(
                          (r) => DropdownMenuItem<String>(
                            value: r,
                            child: Text(r),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setM(() => role = v ?? role),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed:
                          (memberEmail.trim().isEmpty && memberUid.isEmpty)
                          ? null
                          : () => Navigator.pop(ctx, true),
                      child: const Text('Save Member'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    if (ok != true) return;
    try {
      await _runWithLoader('Saving member...', () {
        return _callWithFreshAuth('assignAgencyMemberRoleV2', {
          'agencyId': widget.agencyId,
          if (memberUid.isNotEmpty) 'memberUid': memberUid,
          if (memberUid.isEmpty) 'memberEmail': memberEmail.trim().toLowerCase(),
          'role': role,
        });
      });
      _toast('Member saved successfully.', success: true);
    } catch (e) {
      _toast('Save failed: $e');
    }
  }

  Future<void> _changeRole({
    required String uid,
    required String email,
    required String role,
  }) async {
    try {
      await _runWithLoader('Updating role...', () {
        return _callWithFreshAuth('assignAgencyMemberRoleV2', {
          'agencyId': widget.agencyId,
          if (email.trim().isNotEmpty) 'memberEmail': email,
          if (email.trim().isEmpty) 'memberUid': uid,
          'role': role,
        });
      });
      _toast('Role updated.', success: true);
    } catch (e) {
      _toast('Role update failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _openAddMemberForm,
                  icon: const Icon(Icons.person_add_alt_1_rounded),
                  label: const Text('Add Member'),
                ),
              ),
            ),
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: _fs
                    .collection('agency_members')
                    .where('agencyId', isEqualTo: widget.agencyId)
                    .where('active', isEqualTo: true)
                    .limit(200)
                    .snapshots(),
                builder: (context, snap) {
                  if (snap.hasError) {
                    return Center(
                      child: Text('Members failed: ${snap.error}'),
                    );
                  }
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final docs = snap.data!.docs;
                  if (docs.isEmpty) {
                    return const Center(child: Text('No active members yet.'));
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 14),
                    itemCount: docs.length,
                    itemBuilder: (context, i) {
                      final d = docs[i];
                      final m = d.data();
                      final role = '${m['role'] ?? 'agency_staff'}'.trim();
                      final email = '${m['email'] ?? ''}'.trim();
                      final uid = d.id;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: ListTile(
                          leading: const CircleAvatar(
                            child: Icon(Icons.person_rounded),
                          ),
                          title: Text(email.isEmpty ? uid : email),
                          subtitle: Text('Role: $role'),
                          trailing: PopupMenuButton<String>(
                            onSelected: (v) {
                              if (v == role) return;
                              _changeRole(uid: uid, email: email, role: v);
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: 'agency_admin',
                                child: Text('agency_admin'),
                              ),
                              PopupMenuItem(
                                value: 'agency_staff',
                                child: Text('agency_staff'),
                              ),
                              PopupMenuItem(
                                value: 'dispatcher',
                                child: Text('dispatcher'),
                              ),
                              PopupMenuItem(
                                value: 'finance',
                                child: Text('finance'),
                              ),
                              PopupMenuItem(
                                value: 'viewer',
                                child: Text('viewer'),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
        if (_actionLoading)
          Positioned.fill(
            child: Container(
              color: const Color(0x66000000),
              alignment: Alignment.center,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white24),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _actionText,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
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
  bool _actionLoading = false;
  String _actionText = 'Processing request...';

  Future<T> _runWithLoader<T>(
    String message,
    Future<T> Function() action,
  ) async {
    if (mounted) {
      setState(() {
        _actionLoading = true;
        _actionText = message;
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
          child: SingleChildScrollView(
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
                    isExpanded: true,
                    initialValue: directionId,
                    decoration: const InputDecoration(labelText: 'Direction'),
                    items: directions.map((d) {
                      final m = d.data();
                      final corridor = '${m['corridorName'] ?? 'Corridor'}';
                      final label = '${m['directionLabel'] ?? 'direction'}';
                      final stops =
                          (m['stopNames'] as List<dynamic>? ?? const [])
                              .map((e) => '$e')
                              .join(' -> ');
                      return DropdownMenuItem(
                        value: d.id,
                        child: Text(
                          '$corridor ($label): $stops',
                          maxLines: 1,
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
      ),
    );

    if (ok != true || directionId == null) return;
    try {
      await _runWithLoader('Assigning direction...', () {
        return _callWithFreshAuth('assignBusDirectionV2', {
          'agencyId': widget.agencyId,
          'busId': busId,
          'directionId': directionId,
        });
      });
      _toast('Direction assigned to $busId.', success: true);
    } catch (e) {
      _toast('Assign failed: $e');
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
          return Center(
              child: Text('Directions load failed: ${directionSnap.error}'));
        }
        if (!directionSnap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final directionDocs = directionSnap.data!.docs;
        final directionById =
            <String, QueryDocumentSnapshot<Map<String, dynamic>>>{
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
              return Center(
                  child: Text('Assignments load failed: ${assignSnap.error}'));
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
                  return Center(
                      child: Text('Fleet load failed: ${rtdbSnap.error}'));
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
                    child: Text(
                        'No buses found for "${widget.agencyName}" in realtime devices.'),
                  );
                }

                return Stack(
                  children: [
                    ListView.builder(
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

                        final assignment =
                            assignByBusId[busId] ?? const <String, dynamic>{};
                        final directionId =
                            '${assignment['directionId'] ?? ''}'.trim();
                        final directionDoc = directionById[directionId];
                        final direction = directionDoc?.data();
                        final corridor =
                            '${direction?['corridorName'] ?? ''}'.trim();
                        final label =
                            '${direction?['directionLabel'] ?? ''}'.trim();
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
                                _toast(
                                  'Fare setup moved to Super Admin directions.',
                                  success: true,
                                );
                              },
                              itemBuilder: (context) => const [
                                PopupMenuItem(
                                  value: 'assign',
                                  child: Text('Assign direction'),
                                ),
                                PopupMenuItem(
                                  value: 'fare',
                                  child: Text('Fare managed by Super Admin'),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                    if (_actionLoading)
                      Positioned.fill(
                        child: Container(
                          color: const Color(0x66000000),
                          alignment: Alignment.center,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0F172A),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white24),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  _actionText,
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }
}

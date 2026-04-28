import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:spotlight_traffic_app/core/widgets/spotlight_loader.dart';
import 'package:spotlight_traffic_app/core/widgets/spotlight_toast.dart';

class SuperAdminConsolePage extends StatefulWidget {
  const SuperAdminConsolePage({super.key});

  @override
  State<SuperAdminConsolePage> createState() => _SuperAdminConsolePageState();
}

class _SuperAdminConsolePageState extends State<SuperAdminConsolePage>
    with SingleTickerProviderStateMixin {
  final _fx = FirebaseFunctions.instanceFor(region: 'us-central1');
  final _fs = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;
  final _cardSearchCtrl = TextEditingController();
  String _cardSearch = '';
  bool _actionLoading = false;
  String _actionLoadingText = 'Processing request...';
  late final TabController _tab = TabController(length: 3, vsync: this);

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

  Future<void> _callAsSuper(String fn, Map<String, dynamic> data) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Sign in required.');
    }
    final idToken = await user.getIdToken(true);
    await _fx.httpsCallable(fn).call({...data, 'idToken': idToken});
  }

  bool _matchesCardSearch(String cardId, Map<String, dynamic> m) {
    final q = _cardSearch.trim().toLowerCase();
    if (q.isEmpty) return true;

    final userEmail = '${m['userEmail'] ?? ''}'.toLowerCase();
    final userName = '${m['userName'] ?? m['displayName'] ?? ''}'.toLowerCase();
    final userId = '${m['userId'] ?? ''}'.toLowerCase();
    final rfid = '${m['rfidUid'] ?? ''}'.toLowerCase();
    final agency = '${m['issuerAgencyId'] ?? 'global'}'.toLowerCase();
    final id = cardId.toLowerCase();

    return id.contains(q) ||
        userEmail.contains(q) ||
        userName.contains(q) ||
        userId.contains(q) ||
        rfid.contains(q) ||
        agency.contains(q);
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
                  final hay =
                      '${u['name']} ${u['email']} ${u['id']}'.toLowerCase();
                  return q.isEmpty || hay.contains(q);
                })
                .take(80)
                .toList();

            return AlertDialog(
              title: const Text('Select user'),
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
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 320,
                      child: filtered.isEmpty
                          ? const Center(child: Text('No matching users.'))
                          : ListView.builder(
                              itemCount: filtered.length,
                              itemBuilder: (ctx, i) {
                                final u = filtered[i];
                                return ListTile(
                                  dense: true,
                                  title: Text(
                                    u['name']!.isEmpty
                                        ? '(No name)'
                                        : u['name']!,
                                  ),
                                  subtitle: Text(
                                    u['email']!.isEmpty
                                        ? u['id']!
                                        : u['email']!,
                                  ),
                                  onTap: () => Navigator.pop(ctx, u),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Close'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<String?> _pickCardIdForUser(Map<String, String> user) async {
    final email = (user['email'] ?? '').trim().toLowerCase();
    final userId = (user['id'] ?? '').trim();

    final byEmail = email.isEmpty
        ? null
        : await _fs
            .collection('cards')
            .where('userEmail', isEqualTo: email)
            .where('active', isEqualTo: true)
            .limit(30)
            .get();
    final byUserId = userId.isEmpty
        ? null
        : await _fs
            .collection('cards')
            .where('userId', isEqualTo: userId)
            .where('active', isEqualTo: true)
            .limit(30)
            .get();
    if (!mounted) return null;

    final merged = <String, Map<String, dynamic>>{};
    for (final d in [...?byEmail?.docs, ...?byUserId?.docs]) {
      merged[d.id] = d.data();
    }
    if (merged.isEmpty) return null;
    if (merged.length == 1) return merged.keys.first;

    final entries = merged.entries.toList();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Select card'),
        content: SizedBox(
          width: 520,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: entries.length,
            itemBuilder: (ctx, i) {
              final e = entries[i];
              final m = e.value;
              return ListTile(
                title: Text(e.key),
                subtitle: Text(
                  'RFID: ${m['rfidUid'] ?? '-'} - Balance: RWF ${m['balanceRwf'] ?? 0}',
                ),
                onTap: () => Navigator.pop(ctx, e.key),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _cardSearchCtrl.dispose();
    _tab.dispose();
    super.dispose();
  }

  Future<void> _review({
    required String applicationId,
    required bool approve,
  }) async {
    if (mounted) {
      setState(() {
        _actionLoading = true;
        _actionLoadingText =
            approve ? 'Approving application...' : 'Rejecting application...';
      });
    }
    try {
      await _callAsSuper('reviewAgencyApplicationV2', {
        'applicationId': applicationId,
        'decision': approve ? 'approve' : 'reject',
      });
      if (!mounted) return;
      showSpotlightToast(
        context,
        approve ? 'Application approved.' : 'Application rejected.',
        success: true,
        margin: const EdgeInsets.fromLTRB(14, 0, 14, 16),
      );
    } catch (e) {
      if (!mounted) return;
      showSpotlightToast(
        context,
        'Review failed: $e',
        success: false,
        margin: const EdgeInsets.fromLTRB(14, 0, 14, 16),
      );
    } finally {
      if (mounted) {
        setState(() => _actionLoading = false);
      }
    }
  }

  Future<void> _createDirectionPairForm() async {
    String corridor = '';
    String stopsCsv = '';
    String fareText = '';
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
                const Text(
                  'Create Direction Pair',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  style: const TextStyle(color: Colors.white),
                  onChanged: (v) => setM(() => corridor = v),
                  decoration: const InputDecoration(labelText: 'Corridor name'),
                ),
                const SizedBox(height: 8),
                TextField(
                  style: const TextStyle(color: Colors.white),
                  onChanged: (v) => setM(() => stopsCsv = v),
                  decoration: const InputDecoration(
                    labelText: 'Stops (comma separated)',
                    helperText:
                        'Example: Remera, Rwamagana, Kayonza, Kibungo, Nyakarambi',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  style: const TextStyle(color: Colors.white),
                  keyboardType: TextInputType.number,
                  onChanged: (v) => setM(() => fareText = v),
                  decoration:
                      const InputDecoration(labelText: 'Default fare (RWF)'),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Create'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (ok != true) return;
    final stops = stopsCsv
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    try {
      await _runWithActionLoader('Creating direction pair...', () {
        return _callAsSuper('createDirectionPairV2', {
          'corridorName': corridor.trim(),
          'stops': stops,
          'defaultFareRwf': int.tryParse(fareText.trim()) ?? 0,
        });
      });
      if (!mounted) return;
      showSpotlightToast(context, 'Direction pair created.', success: true);
    } catch (e) {
      if (!mounted) return;
      showSpotlightToast(context, 'Create failed: $e', success: false);
    }
  }

  Future<void> _editDirectionForm(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    final m = doc.data();
    String corridor = '${m['corridorName'] ?? ''}';
    String stopsCsv = (m['stopNames'] as List<dynamic>? ?? const [])
        .map((e) => '$e')
        .join(', ');
    String fareText = '${(m['defaultFareRwf'] as num?)?.toInt() ?? 0}';
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
                const Text(
                  'Edit Direction Pair',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                TextFormField(
                  initialValue: corridor,
                  style: const TextStyle(color: Colors.white),
                  onChanged: (v) => corridor = v,
                  decoration: const InputDecoration(labelText: 'Corridor name'),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  initialValue: stopsCsv,
                  style: const TextStyle(color: Colors.white),
                  onChanged: (v) => stopsCsv = v,
                  decoration: const InputDecoration(
                      labelText: 'Stops (comma separated)'),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  initialValue: fareText,
                  style: const TextStyle(color: Colors.white),
                  keyboardType: TextInputType.number,
                  onChanged: (v) => fareText = v,
                  decoration: const InputDecoration(labelText: 'Default fare'),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (ok != true) return;
    try {
      await _runWithActionLoader('Updating direction...', () {
        return _callAsSuper('updateDirectionV2', {
          'directionId': doc.id,
          'corridorName': corridor.trim(),
          'stops': stopsCsv
              .split(',')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList(),
          'defaultFareRwf': int.tryParse(fareText.trim()) ?? 0,
        });
      });
      if (!mounted) return;
      showSpotlightToast(context, 'Direction updated.', success: true);
    } catch (e) {
      if (!mounted) return;
      showSpotlightToast(context, 'Update failed: $e', success: false);
    }
  }

  Future<void> _deleteDirectionPair(String directionId) async {
    try {
      await _runWithActionLoader('Deleting direction pair...', () {
        return _callAsSuper(
            'deleteDirectionPairV2', {'directionId': directionId});
      });
      if (!mounted) return;
      showSpotlightToast(context, 'Direction pair deleted.', success: true);
    } catch (e) {
      if (!mounted) return;
      showSpotlightToast(context, 'Delete failed: $e', success: false);
    }
  }

  List<Map<String, dynamic>> _segmentsForStops(List<String> stops) {
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < stops.length - 1; i++) {
      for (var j = i + 1; j < stops.length; j++) {
        out.add({
          'fromIndex': i,
          'toIndex': j,
          'fromName': stops[i],
          'toName': stops[j],
          'key': '${i}_$j',
        });
      }
    }
    return out;
  }

  Map<String, int> _parseDirectionFares(Map raw) {
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

  Future<void> _openSetDirectionFareForm({
    required QueryDocumentSnapshot<Map<String, dynamic>> directionDoc,
    int? presetFromIndex,
    int? presetToIndex,
  }) async {
    final m = directionDoc.data();
    final stops = (m['stopNames'] as List<dynamic>? ?? const [])
        .map((e) => '$e')
        .where((e) => e.trim().isNotEmpty)
        .toList();
    if (stops.length < 2) {
      showSpotlightToast(context, 'Direction has too few stops.',
          success: false);
      return;
    }

    int fromIndex = presetFromIndex ?? 0;
    int toIndex = presetToIndex ?? (fromIndex + 1);
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
                    'Set Global Fare (${m['corridorName'] ?? ''} - ${m['directionLabel'] ?? ''})',
                    style: const TextStyle(
                      color: Colors.white,
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
                        if (toIndex <= fromIndex) toIndex = fromIndex + 1;
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int>(
                    initialValue: toIndex,
                    decoration: const InputDecoration(labelText: 'To stop'),
                    items: toChoices
                        .map((i) => DropdownMenuItem<int>(
                              value: i,
                              child: Text(stops[i]),
                            ))
                        .toList(),
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
      if (!mounted) return;
      showSpotlightToast(context, 'Fare must be a valid positive number.',
          success: false);
      return;
    }

    try {
      await _runWithActionLoader('Saving global fare...', () {
        return _callAsSuper('setDirectionSegmentFareV2', {
          'directionId': directionDoc.id,
          'fromStopIndex': fromIndex,
          'toStopIndex': toIndex,
          'fareRwf': fareRwf,
        });
      });
      if (!mounted) return;
      showSpotlightToast(context, 'Fare saved globally.', success: true);
    } catch (e) {
      if (!mounted) return;
      showSpotlightToast(context, 'Save fare failed: $e', success: false);
    }
  }

  Future<void> _deleteDirectionFare({
    required QueryDocumentSnapshot<Map<String, dynamic>> directionDoc,
    required int fromIndex,
    required int toIndex,
  }) async {
    try {
      await _runWithActionLoader('Deleting global fare...', () {
        return _callAsSuper('deleteDirectionSegmentFareV2', {
          'directionId': directionDoc.id,
          'fromStopIndex': fromIndex,
          'toStopIndex': toIndex,
        });
      });
      if (!mounted) return;
      showSpotlightToast(context, 'Fare deleted.', success: true);
    } catch (e) {
      if (!mounted) return;
      showSpotlightToast(context, 'Delete fare failed: $e', success: false);
    }
  }

  Future<void> _openExtendCorridorForm({
    required QueryDocumentSnapshot<Map<String, dynamic>> directionDoc,
  }) async {
    String newStop = '';
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
                const Text(
                  'Extend Corridor (Add Terminal Stop)',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                TextField(
                  style: const TextStyle(color: Colors.white),
                  onChanged: (v) => setM(() => newStop = v),
                  decoration: const InputDecoration(
                    labelText: 'New terminal stop',
                  ),
                ),
                const SizedBox(height: 8),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Note: extending resets chunk fares for this pair to avoid bad index mapping.',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: newStop.trim().isEmpty
                        ? null
                        : () => Navigator.pop(ctx, true),
                    child: const Text('Extend'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (ok != true) return;
    try {
      await _runWithActionLoader('Extending corridor...', () {
        return _callAsSuper('extendDirectionPairV2', {
          'directionId': directionDoc.id,
          'newStopName': newStop.trim(),
        });
      });
      if (!mounted) return;
      showSpotlightToast(context, 'Corridor extended. Re-set fares now.',
          success: true);
    } catch (e) {
      if (!mounted) return;
      showSpotlightToast(context, 'Extend failed: $e', success: false);
    }
  }

  Future<Map<String, dynamic>> _loadFinanceOverview() async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Sign in required');
    final idToken = await user.getIdToken(true);
    final res = await _fx.httpsCallable('getFinanceOverviewV2').call({
      'idToken': idToken,
    });
    final data = res.data;
    if (data is Map) {
      return Map<String, dynamic>.from(data.map((k, v) => MapEntry('$k', v)));
    }
    throw Exception('Finance response was not an object.');
  }

  String _rwf(num? value) => 'RWF ${(value ?? 0).toInt()}';

  Future<void> _openSetGlobalRoleForm() async {
    String memberEmail = '';
    String memberName = '';
    const roles = <String>[
      'rider',
      'agency_admin',
      'agency_staff',
      'dispatcher',
      'finance',
      'viewer',
      'super_admin',
    ];
    String role = 'rider';

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
                const Text(
                  'Set User Global Role',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final pickedUser = await _pickTrafficUser();
                      if (pickedUser == null || !ctx.mounted) return;
                      setM(() {
                        memberEmail =
                            (pickedUser['email'] ?? '').trim().toLowerCase();
                        memberName = (pickedUser['name'] ?? '').trim();
                      });
                    },
                    icon: const Icon(Icons.person_search_rounded),
                    label: const Text('Find user'),
                  ),
                ),
                if (memberName.trim().isNotEmpty ||
                    memberEmail.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Selected: ${memberName.trim().isEmpty ? '(No name)' : memberName.trim()}'
                        '${memberEmail.trim().isEmpty ? '' : ' <$memberEmail>'}',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12),
                      ),
                    ),
                  ),
                TextFormField(
                  key: ValueKey('global-role-email-$memberEmail'),
                  initialValue: memberEmail.trim().isEmpty ? null : memberEmail,
                  style: const TextStyle(color: Colors.white),
                  keyboardType: TextInputType.emailAddress,
                  onChanged: (v) => setM(() => memberEmail = v),
                  decoration: const InputDecoration(
                    labelText: 'User email',
                    hintText: 'example@mail.com',
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: role,
                  decoration: const InputDecoration(labelText: 'Role'),
                  items: roles
                      .map((r) =>
                          DropdownMenuItem<String>(value: r, child: Text(r)))
                      .toList(),
                  onChanged: (v) => setM(() => role = v ?? role),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: memberEmail.trim().isEmpty
                        ? null
                        : () => Navigator.pop(ctx, true),
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (ok != true) return;
    try {
      await _runWithActionLoader('Updating user role...', () {
        return _callAsSuper('setUserGlobalRoleV2', {
          'memberEmail': memberEmail.trim().toLowerCase(),
          'role': role,
        });
      });
      if (!mounted) return;
      showSpotlightToast(context, 'User role updated.', success: true);
    } catch (e) {
      if (!mounted) return;
      showSpotlightToast(context, 'Role update failed: $e', success: false);
    }
  }

  Future<void> _issueCardForm() async {
    String riderEmail = '';
    String riderName = '';
    String rfidUid = '';
    String initialBalance = '';

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
                const Text(
                  'Issue Global Card',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                TextField(
                  style: const TextStyle(color: Colors.white),
                  onChanged: (v) => setM(() => riderEmail = v),
                  decoration: const InputDecoration(labelText: 'Rider email'),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final picked = await _pickTrafficUser();
                      if (picked == null || !ctx.mounted) return;
                      setM(() {
                        riderEmail = picked['email'] ?? '';
                        riderName = picked['name'] ?? '';
                      });
                    },
                    icon: const Icon(Icons.person_search_rounded),
                    label: const Text('Find user'),
                  ),
                ),
                if (riderName.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Selected: $riderName',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                TextField(
                  style: const TextStyle(color: Colors.white),
                  onChanged: (v) => setM(() => rfidUid = v),
                  decoration: const InputDecoration(labelText: 'RFID UID'),
                ),
                const SizedBox(height: 8),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Issuer: Msafiri',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  style: const TextStyle(color: Colors.white),
                  keyboardType: TextInputType.number,
                  onChanged: (v) => setM(() => initialBalance = v),
                  decoration:
                      const InputDecoration(labelText: 'Initial balance (RWF)'),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Issue'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (ok != true) return;
    try {
      await _runWithActionLoader('Issuing card...', () {
        return _callAsSuper('issueRfidCardToUserV2', {
          'riderEmail': riderEmail.trim().toLowerCase(),
          'rfidUid': rfidUid.trim(),
          'issuerAgencyId': 'msafiri',
          'initialBalanceRwf': int.tryParse(initialBalance.trim()) ?? 0,
        });
      });
      if (!mounted) return;
      showSpotlightToast(context, 'Card issued.', success: true);
    } catch (e) {
      if (!mounted) return;
      showSpotlightToast(context, 'Issue failed: $e', success: false);
    }
  }

  Future<void> _topUpCardForm() async {
    String riderName = '';
    String cardId = '';
    String amount = '';
    String note = '';
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
                const Text(
                  'Top Up Card',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final pickedUser = await _pickTrafficUser();
                      if (pickedUser == null || !ctx.mounted) return;
                      final pickedCardId = await _pickCardIdForUser(pickedUser);
                      if (!ctx.mounted) return;
                      setM(() {
                        riderName = pickedUser['name'] ?? '';
                        if (pickedCardId != null) {
                          cardId = pickedCardId;
                        }
                      });
                      if (pickedCardId == null) {
                        if (!mounted) return;
                        showSpotlightToast(
                          context,
                          'No cards found for that user yet.',
                          success: false,
                        );
                      }
                    },
                    icon: const Icon(Icons.person_search_rounded),
                    label: const Text('Find user'),
                  ),
                ),
                if (riderName.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Selected: $riderName',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                TextFormField(
                  key: ValueKey('topup-card-$cardId'),
                  style: const TextStyle(color: Colors.white),
                  initialValue: cardId,
                  onChanged: (v) => setM(() => cardId = v),
                  decoration: const InputDecoration(labelText: 'Card ID'),
                ),
                const SizedBox(height: 8),
                TextField(
                  style: const TextStyle(color: Colors.white),
                  keyboardType: TextInputType.number,
                  onChanged: (v) => setM(() => amount = v),
                  decoration: const InputDecoration(labelText: 'Amount (RWF)'),
                ),
                const SizedBox(height: 8),
                TextField(
                  style: const TextStyle(color: Colors.white),
                  onChanged: (v) => setM(() => note = v),
                  decoration: const InputDecoration(labelText: 'Note'),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Top up'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (ok != true) return;
    try {
      await _runWithActionLoader('Applying top up...', () {
        return _callAsSuper('topUpAgencyCardV2', {
          'cardId': cardId.trim(),
          'amountRwf': int.tryParse(amount.trim()) ?? 0,
          'note': note.trim(),
        });
      });
      if (!mounted) return;
      showSpotlightToast(context, 'Top up applied.', success: true);
    } catch (e) {
      if (!mounted) return;
      showSpotlightToast(context, 'Top up failed: $e', success: false);
    }
  }

  Future<void> _replaceCardForm() async {
    String riderEmail = '';
    String riderName = '';
    String oldCardId = '';
    String newRfid = '';
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
                const Text(
                  'Replace Lost Card',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                TextField(
                  style: const TextStyle(color: Colors.white),
                  onChanged: (v) => setM(() => riderEmail = v),
                  decoration: const InputDecoration(labelText: 'Rider email'),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final picked = await _pickTrafficUser();
                      if (picked == null || !ctx.mounted) return;
                      final pickedCardId = await _pickCardIdForUser(picked);
                      if (!ctx.mounted) return;
                      setM(() {
                        riderEmail = picked['email'] ?? '';
                        riderName = picked['name'] ?? '';
                        if (pickedCardId != null) {
                          oldCardId = pickedCardId;
                        }
                      });
                      if (pickedCardId == null) {
                        if (!mounted) return;
                        showSpotlightToast(
                          context,
                          'No active cards found for that user.',
                          success: false,
                        );
                      }
                    },
                    icon: const Icon(Icons.person_search_rounded),
                    label: const Text('Find user'),
                  ),
                ),
                if (riderName.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Selected: $riderName',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                TextFormField(
                  key: ValueKey('replace-old-card-$oldCardId'),
                  style: const TextStyle(color: Colors.white),
                  initialValue: oldCardId,
                  onChanged: (v) => setM(() => oldCardId = v),
                  decoration: const InputDecoration(
                      labelText: 'Old card ID (optional)'),
                ),
                const SizedBox(height: 8),
                TextField(
                  style: const TextStyle(color: Colors.white),
                  onChanged: (v) => setM(() => newRfid = v),
                  decoration: const InputDecoration(labelText: 'New RFID UID'),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Replace'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (ok != true) return;
    try {
      final payload = <String, dynamic>{
        'riderEmail': riderEmail.trim().toLowerCase(),
        'newRfidUid': newRfid.trim(),
      };
      if (oldCardId.trim().isNotEmpty) {
        payload['oldCardId'] = oldCardId.trim();
      }
      await _runWithActionLoader('Replacing card...', () {
        return _callAsSuper('replaceLostRfidCardV2', payload);
      });
      if (!mounted) return;
      showSpotlightToast(context, 'Card replaced.', success: true);
    } catch (e) {
      if (!mounted) return;
      showSpotlightToast(context, 'Replace failed: $e', success: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Super Admin Console'),
        actions: [
          IconButton(
            tooltip: 'Set user role',
            onPressed: _openSetGlobalRoleForm,
            icon: const Icon(Icons.manage_accounts_rounded),
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: 'Overview'),
            Tab(text: 'Directions'),
            Tab(text: 'Cards'),
          ],
        ),
      ),
      body: Stack(
        children: [
          TabBarView(
            controller: _tab,
            children: [
              ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  FutureBuilder<Map<String, dynamic>>(
                    future: _loadFinanceOverview(),
                    builder: (context, snap) {
                      if (snap.connectionState == ConnectionState.waiting) {
                        return const LinearProgressIndicator(minHeight: 2);
                      }
                      if (snap.hasError) {
                        return Card(
                          child: ListTile(
                            title: const Text('Finance overview failed'),
                            subtitle: Text('${snap.error}'),
                          ),
                        );
                      }
                      final data = snap.data ?? const {};
                      final agencies =
                          (data['agencies'] as List<dynamic>? ?? const []);
                      final totalCollectionRwf =
                          (data['totalCollectionRwf'] as num?)?.toInt() ?? 0;
                      final totalCommissionRwf =
                          (data['totalCommissionRwf'] as num?)?.toInt() ?? 0;

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Card(
                                  child: ListTile(
                                    title: const Text('Total Collection'),
                                    subtitle: Text(_rwf(totalCollectionRwf)),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Card(
                                  child: ListTile(
                                    title: const Text('Msafiri 5% Total'),
                                    subtitle: Text(_rwf(totalCommissionRwf)),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Agency Totals',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          ...agencies.whereType<Map>().map((raw) {
                            final a = Map<String, dynamic>.from(
                              raw.map((k, v) => MapEntry('$k', v)),
                            );
                            final agencyId = '${a['agencyId'] ?? '-'}';
                            final totalPaidRwf =
                                (a['totalPaidRwf'] as num?)?.toInt() ?? 0;
                            final commissionRwf =
                                (a['commissionRwf'] as num?)?.toInt() ?? 0;
                            return Card(
                              margin: const EdgeInsets.only(bottom: 8),
                              child: ListTile(
                                title: Text(agencyId),
                                subtitle: Text(
                                  'Paid: ${_rwf(totalPaidRwf)} - 5%: ${_rwf(commissionRwf)}',
                                ),
                              ),
                            );
                          }),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Pending Approvals',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: _fs
                        .collection('agency_applications')
                        .where('status', isEqualTo: 'pending')
                        .orderBy('submittedAt', descending: true)
                        .limit(100)
                        .snapshots(),
                    builder: (context, snap) {
                      if (snap.hasError) return Text('${snap.error}');
                      if (!snap.hasData) {
                        return const LinearProgressIndicator(minHeight: 2);
                      }
                      final docs = snap.data!.docs;
                      if (docs.isEmpty) {
                        return const Card(
                          child:
                              ListTile(title: Text('No pending applications.')),
                        );
                      }
                      return Column(
                        children: docs.map((d) {
                          final m = d.data();
                          return Card(
                            margin: const EdgeInsets.only(bottom: 10),
                            child: ListTile(
                              title: Text('${m['agencyName'] ?? 'Agency'}'),
                              subtitle: Text(
                                'Phone: ${m['phone'] ?? '-'} - Fleet: ${m['fleetSize'] ?? '-'}',
                              ),
                              trailing: Wrap(
                                spacing: 8,
                                children: [
                                  OutlinedButton(
                                    onPressed: () => _review(
                                        applicationId: d.id, approve: false),
                                    child: const Text('Reject'),
                                  ),
                                  FilledButton(
                                    onPressed: () => _review(
                                        applicationId: d.id, approve: true),
                                    child: const Text('Approve'),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      );
                    },
                  ),
                ],
              ),
              Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                    child: Column(
                      children: [
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _createDirectionPairForm,
                            icon: const Icon(Icons.alt_route_rounded),
                            label: const Text('Create Direction Pair'),
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Super admin manages global chunk fares. Agencies only assign directions.',
                          style: TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: _fs
                          .collection('route_directions')
                          .where('active', isEqualTo: true)
                          .limit(200)
                          .snapshots(),
                      builder: (context, snap) {
                        if (snap.hasError) {
                          return Center(child: Text('${snap.error}'));
                        }
                        if (!snap.hasData) {
                          return const Center(
                              child: CircularProgressIndicator());
                        }
                        final docs = snap.data!.docs;
                        if (docs.isEmpty) {
                          return const Center(
                              child: Text('No directions yet.'));
                        }
                        return ListView.builder(
                          padding: const EdgeInsets.all(12),
                          itemCount: docs.length,
                          itemBuilder: (context, i) {
                            final d = docs[i];
                            final m = d.data();
                            final stops =
                                (m['stopNames'] as List<dynamic>? ?? const [])
                                    .map((e) => '$e')
                                    .toList();
                            final fares = _parseDirectionFares(
                              m['faresBySegment'] as Map? ?? const {},
                            );
                            final segments = _segmentsForStops(stops);
                            final missingFareCount = segments
                                .where((s) => fares['${s['key']}'] == null)
                                .length;
                            return Card(
                              margin: const EdgeInsets.only(bottom: 10),
                              child: ExpansionTile(
                                title: Text(
                                  '${m['corridorName'] ?? 'Corridor'} (${m['directionLabel'] ?? ''})',
                                ),
                                subtitle: Text(
                                  'Stops: ${stops.join(' -> ')}\nDefault: ${_rwf((m['defaultFareRwf'] as num?)?.toInt() ?? 0)}',
                                ),
                                childrenPadding:
                                    const EdgeInsets.fromLTRB(12, 0, 12, 10),
                                trailing: PopupMenuButton<String>(
                                  onSelected: (value) {
                                    if (value == 'edit') {
                                      _editDirectionForm(d);
                                      return;
                                    }
                                    _deleteDirectionPair(d.id);
                                  },
                                  itemBuilder: (context) => const [
                                    PopupMenuItem(
                                      value: 'edit',
                                      child: Text('Edit'),
                                    ),
                                    PopupMenuItem(
                                      value: 'delete',
                                      child: Text('Delete pair'),
                                    ),
                                  ],
                                ),
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: OutlinedButton.icon(
                                          onPressed: () =>
                                              _openSetDirectionFareForm(
                                            directionDoc: d,
                                          ),
                                          icon: const Icon(
                                              Icons.payments_rounded),
                                          label: const Text('Set chunk fare'),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: OutlinedButton.icon(
                                          onPressed: () =>
                                              _openExtendCorridorForm(
                                            directionDoc: d,
                                          ),
                                          icon: const Icon(
                                              Icons.add_road_rounded),
                                          label: const Text('Extend corridor'),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  if (segments.isNotEmpty &&
                                      missingFareCount > 0)
                                    Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        'Missing fares: $missingFareCount chunk(s) locked for users.',
                                        style: const TextStyle(
                                          color: Color(0xFFB45309),
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  if (segments.isNotEmpty &&
                                      missingFareCount > 0)
                                    const SizedBox(height: 8),
                                  if (segments.isEmpty)
                                    const Align(
                                      alignment: Alignment.centerLeft,
                                      child:
                                          Text('No chunks for this direction.'),
                                    )
                                  else
                                    ...segments.map((s) {
                                      final key = '${s['key']}';
                                      final fare = fares[key];
                                      return ListTile(
                                        dense: true,
                                        contentPadding: EdgeInsets.zero,
                                        title: Text(
                                          '${s['fromName']} -> ${s['toName']}',
                                        ),
                                        subtitle: Text(
                                          fare == null
                                              ? 'No fare set'
                                              : 'Fare: ${_rwf(fare)}',
                                        ),
                                        trailing: Wrap(
                                          spacing: 6,
                                          children: [
                                            IconButton(
                                              tooltip: 'Edit fare',
                                              onPressed: () =>
                                                  _openSetDirectionFareForm(
                                                directionDoc: d,
                                                presetFromIndex:
                                                    s['fromIndex'] as int,
                                                presetToIndex:
                                                    s['toIndex'] as int,
                                              ),
                                              icon: const Icon(
                                                  Icons.edit_rounded),
                                            ),
                                            IconButton(
                                              tooltip: 'Delete fare',
                                              onPressed: fare == null
                                                  ? null
                                                  : () => _deleteDirectionFare(
                                                        directionDoc: d,
                                                        fromIndex:
                                                            s['fromIndex']
                                                                as int,
                                                        toIndex:
                                                            s['toIndex'] as int,
                                                      ),
                                              icon: const Icon(
                                                  Icons.delete_outline_rounded),
                                            ),
                                          ],
                                        ),
                                      );
                                    }),
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
              Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                    child: Column(
                      children: [
                        TextField(
                          controller: _cardSearchCtrl,
                          onChanged: (v) => setState(() => _cardSearch = v),
                          decoration: InputDecoration(
                            hintText:
                                'Search by name, email, RFID, card ID, agency',
                            prefixIcon: const Icon(Icons.search_rounded),
                            suffixIcon: _cardSearch.isEmpty
                                ? null
                                : IconButton(
                                    onPressed: () {
                                      _cardSearchCtrl.clear();
                                      setState(() => _cardSearch = '');
                                    },
                                    icon: const Icon(Icons.clear_rounded),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              onPressed: _issueCardForm,
                              icon: const Icon(Icons.contactless_rounded),
                              label: const Text('Issue Card'),
                            ),
                            FilledButton.icon(
                              onPressed: _topUpCardForm,
                              icon: const Icon(Icons.add_card_rounded),
                              label: const Text('Top Up'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _replaceCardForm,
                              icon: const Icon(Icons.swap_horiz_rounded),
                              label: const Text('Replace Lost'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: _fs.collection('cards').limit(200).snapshots(),
                      builder: (context, snap) {
                        if (snap.hasError) {
                          return Center(child: Text('${snap.error}'));
                        }
                        if (!snap.hasData) {
                          return const Center(
                              child: CircularProgressIndicator());
                        }
                        final docs = snap.data!.docs;
                        if (docs.isEmpty) {
                          return const Center(child: Text('No cards yet.'));
                        }
                        final filtered = docs
                            .where((d) => _matchesCardSearch(d.id, d.data()))
                            .toList();
                        if (filtered.isEmpty) {
                          return const Center(
                              child: Text('No cards match your search.'));
                        }
                        final activeCards = filtered.where((d) {
                          final m = d.data();
                          return m['active'] == true &&
                              '${m['status'] ?? ''}' != 'lost_replaced';
                        }).toList();
                        final replacedCards = filtered.where((d) {
                          final m = d.data();
                          return m['active'] != true ||
                              '${m['status'] ?? ''}' == 'lost_replaced';
                        }).toList();

                        return ListView(
                          padding: const EdgeInsets.all(12),
                          children: [
                            Text(
                              'Active Cards (${activeCards.length})',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            ...activeCards.map((d) {
                              final m = d.data();
                              final who =
                                  '${m['userName'] ?? m['displayName'] ?? ''}'
                                      .trim();
                              final email =
                                  '${m['userEmail'] ?? m['userId'] ?? '-'}';
                              return Card(
                                margin: const EdgeInsets.only(bottom: 10),
                                child: ListTile(
                                  title: Text(d.id),
                                  subtitle: Text(
                                    'User: ${who.isEmpty ? email : '$who <$email>'}\n'
                                    'RFID: ${m['rfidUid'] ?? '-'}\n'
                                    'Agency: ${m['issuerAgencyId'] ?? 'global'} - Balance: RWF ${m['balanceRwf'] ?? 0}',
                                  ),
                                  isThreeLine: true,
                                ),
                              );
                            }),
                            const SizedBox(height: 8),
                            Text(
                              'Replaced / Inactive Cards (${replacedCards.length})',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            ...replacedCards.map((d) {
                              final m = d.data();
                              final who =
                                  '${m['userName'] ?? m['displayName'] ?? ''}'
                                      .trim();
                              final email =
                                  '${m['userEmail'] ?? m['userId'] ?? '-'}';
                              final status = '${m['status'] ?? 'inactive'}';
                              return Card(
                                margin: const EdgeInsets.only(bottom: 10),
                                child: ListTile(
                                  title: Text(d.id),
                                  subtitle: Text(
                                    'User: ${who.isEmpty ? email : '$who <$email>'}\n'
                                    'RFID: ${m['rfidUid'] ?? '-'} - Status: $status\n'
                                    'Agency: ${m['issuerAgencyId'] ?? 'global'} - Balance: RWF ${m['balanceRwf'] ?? 0}',
                                  ),
                                  isThreeLine: true,
                                ),
                              );
                            }),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (_actionLoading)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: const Color(0xB3000000),
                  alignment: Alignment.center,
                  child: Container(
                    width: 230,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xE610172A),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
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
        ],
      ),
    );
  }
}

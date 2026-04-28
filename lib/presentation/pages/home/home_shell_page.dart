import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:spotlight_traffic_app/core/widgets/spotlight_loader.dart';
import 'package:spotlight_traffic_app/core/widgets/spotlight_toast.dart';
import 'package:spotlight_traffic_app/presentation/pages/agency/agency_workspace_page.dart';
import 'package:spotlight_traffic_app/presentation/pages/super_admin/super_admin_console_page.dart';
import 'package:spotlight_traffic_app/presentation/pages/traffic/traffic_management_page.dart';

class HomeShellPage extends StatefulWidget {
  const HomeShellPage({super.key, this.initialBusId});

  final String? initialBusId;

  @override
  State<HomeShellPage> createState() => _HomeShellPageState();
}

class _HomeShellPageState extends State<HomeShellPage> {
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = 1;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          const _AgenciesTab(),
          TrafficManagementPage(
            initialBusId: widget.initialBusId,
            embeddedInShell: true,
          ),
          const _SettingsTab(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.apartment_rounded),
            label: 'Agencies',
          ),
          NavigationDestination(
            icon: Icon(Icons.traffic_rounded),
            label: 'Traffic',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_rounded),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

class _AgenciesTab extends StatefulWidget {
  const _AgenciesTab();

  @override
  State<_AgenciesTab> createState() => _AgenciesTabState();
}

class _AgenciesTabState extends State<_AgenciesTab> {
  static const _superAdminEmail = 'nelsonjembe99@gmail.com';

  final _fx = FirebaseFunctions.instanceFor(region: 'us-central1');
  final _fs = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;
  bool _actionLoading = false;
  String _actionLoadingText = 'Processing request...';

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
    showSpotlightToast(
      context,
      text,
      success: success,
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 16),
    );
  }

  Future<void> _openCreateAgencyForm() async {
    String agencyName = '';
    String phone = '';
    String fleetText = '';
    String password = '';
    bool obscure = true;

    final payload = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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
                    'Create Agency Application',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    style: const TextStyle(color: Colors.white),
                    onChanged: (v) => setM(() => agencyName = v),
                    decoration: const InputDecoration(labelText: 'Agency name'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    style: const TextStyle(color: Colors.white),
                    keyboardType: TextInputType.phone,
                    onChanged: (v) => setM(() => phone = v),
                    decoration:
                        const InputDecoration(labelText: 'Phone number'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    style: const TextStyle(color: Colors.white),
                    keyboardType: TextInputType.number,
                    onChanged: (v) => setM(() => fleetText = v),
                    decoration:
                        const InputDecoration(labelText: 'Number of vehicles'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    obscureText: obscure,
                    style: const TextStyle(color: Colors.white),
                    onChanged: (v) => setM(() => password = v),
                    decoration: InputDecoration(
                      labelText: 'Agency password',
                      suffixIcon: IconButton(
                        onPressed: () => setM(() => obscure = !obscure),
                        icon: Icon(
                            obscure ? Icons.visibility_off : Icons.visibility),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () {
                        final fleet = int.tryParse(fleetText.trim());
                        if (agencyName.trim().isEmpty ||
                            phone.trim().isEmpty ||
                            fleet == null ||
                            fleet <= 0 ||
                            password.trim().length < 4) {
                          return;
                        }
                        Navigator.pop(ctx, {
                          'agencyName': agencyName.trim(),
                          'phone': phone.trim(),
                          'fleetSize': fleet,
                          'agencyPassword': password.trim(),
                        });
                      },
                      child: const Text('Submit for Approval'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    if (payload == null) return;
    try {
      await _runWithActionLoader('Submitting agency request...', () {
        return _callWithFreshAuth('submitAgencyApplicationV2', payload);
      });
      _toast('Application submitted. Super admin will review.', success: true);
    } catch (e) {
      _toast('Submit failed: $e');
    }
  }

  Future<void> _openAgencyByPassword({
    required String agencyId,
    required String agencyName,
  }) async {
    String pass = '';
    bool obscure = true;
    final shouldOpen = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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
                  'Open $agencyName',
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 18),
                ),
                const SizedBox(height: 10),
                TextField(
                  obscureText: obscure,
                  style: const TextStyle(color: Colors.white),
                  onChanged: (v) => setM(() => pass = v),
                  decoration: InputDecoration(
                    labelText: 'Agency password',
                    suffixIcon: IconButton(
                      onPressed: () => setM(() => obscure = !obscure),
                      icon: Icon(
                          obscure ? Icons.visibility_off : Icons.visibility),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: pass.trim().isEmpty
                        ? null
                        : () => Navigator.pop(ctx, true),
                    child: const Text('Open'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (shouldOpen != true) return;
    try {
      await _runWithActionLoader('Opening agency workspace...', () {
        return _callWithFreshAuth('openAgencyByPasswordV2', {
          'agencyId': agencyId,
          'password': pass.trim(),
        });
      });
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AgencyWorkspacePage(
            agencyId: agencyId,
            agencyName: agencyName,
          ),
        ),
      );
    } catch (e) {
      _toast('Open failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = _auth.currentUser?.uid;
    final email = (_auth.currentUser?.email ?? '').trim().toLowerCase();
    final isSuperAdmin = email == _superAdminEmail;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Agencies'),
        actions: [
          IconButton(
            tooltip:
                isSuperAdmin ? 'Open Super Admin Console' : 'Restricted View',
            onPressed: () async {
              if (!isSuperAdmin) {
                _toast('Restricted mode: super admins only.', success: true);
                return;
              }
              if (!mounted) return;
              await Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => const SuperAdminConsolePage()),
              );
            },
            icon: Icon(
              isSuperAdmin
                  ? Icons.admin_panel_settings_rounded
                  : Icons.lock_outline_rounded,
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _openCreateAgencyForm,
                    icon: const Icon(Icons.add_business_rounded),
                    label: const Text('Create Agency'),
                  ),
                ),
              ),
              Expanded(
                child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: _fs
                      .collection('agencies')
                      .where('active', isEqualTo: true)
                      .limit(80)
                      .snapshots(),
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return Center(child: Text('${snap.error}'));
                    }
                    if (!snap.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final docs = snap.data!.docs;
                    if (docs.isEmpty) {
                      return const Center(child: Text('No agencies yet.'));
                    }
                    return ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 14),
                      itemCount: docs.length,
                      itemBuilder: (context, i) {
                        final d = docs[i];
                        final m = d.data();
                        final name = '${m['name'] ?? 'Agency'}';
                        final code = '${m['code'] ?? ''}'.trim();
                        return StreamBuilder<
                            DocumentSnapshot<Map<String, dynamic>>>(
                          stream: uid == null
                              ? const Stream.empty()
                              : _fs
                                  .collection('agency_members')
                                  .doc(uid)
                                  .snapshots(),
                          builder: (context, memberSnap) {
                            final member = memberSnap.data?.data() ??
                                const <String, dynamic>{};
                            final belongs =
                                '${member['agencyId'] ?? ''}'.trim() == d.id &&
                                    member['active'] == true;
                            return Card(
                              margin: const EdgeInsets.only(bottom: 10),
                              child: ListTile(
                                leading: CircleAvatar(
                                  child: Text(
                                    (code.isNotEmpty
                                            ? code
                                            : name.substring(0, 1))
                                        .toUpperCase(),
                                  ),
                                ),
                                title: Text(name),
                                subtitle: Text(belongs
                                    ? 'Owned / member agency'
                                    : 'Not joined'),
                                trailing: FilledButton(
                                  onPressed: belongs
                                      ? () => _openAgencyByPassword(
                                            agencyId: d.id,
                                            agencyName: name,
                                          )
                                      : null,
                                  child: const Text('Open'),
                                ),
                              ),
                            );
                          },
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
              child: IgnorePointer(
                child: Container(
                  color: const Color(0xB3000000),
                  alignment: Alignment.center,
                  child: Container(
                    width: 240,
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

class _SettingsTab extends StatefulWidget {
  const _SettingsTab();

  @override
  State<_SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<_SettingsTab> {
  final _fs = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;
  bool _loading = false;

  Future<T> _runWithLoader<T>(String text, Future<T> Function() action) async {
    if (mounted) setState(() => _loading = true);
    try {
      return await action();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<int> _deleteByUser({
    required String collection,
    required String uid,
    List<String>? excludeTypes,
  }) async {
    final excluded = excludeTypes
            ?.map((type) => type.toLowerCase())
            .toSet() ??
        <String>{};
    int deleted = 0;
    while (true) {
      final snap = await _fs
          .collection(collection)
          .where('userId', isEqualTo: uid)
          .limit(300)
          .get();
      if (snap.docs.isEmpty) break;
      final batch = _fs.batch();
      var batchCount = 0;
      for (final d in snap.docs) {
        final type = '${d.data()['type'] ?? ''}'.toLowerCase();
        if (excluded.contains(type)) {
          continue;
        }
        batch.delete(d.reference);
        batchCount += 1;
      }
      if (batchCount > 0) {
        await batch.commit();
        deleted += batchCount;
      }
      if (snap.docs.length < 300) break;
    }
    return deleted;
  }

  @override
  Widget build(BuildContext context) {
    final uid = _auth.currentUser?.uid;
    const options = <int?>[null, 1, 2, 3, 4, 5, 6, 7];
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: uid == null
          ? const Center(child: Text('Sign in required.'))
          : Stack(
              children: [
                StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  stream: _fs.collection('traffic_users').doc(uid).snapshots(),
                  builder: (context, snap) {
                    final data = snap.data?.data() ?? const <String, dynamic>{};
                    final pref = Map<String, dynamic>.from(
                        data['preferences'] as Map? ?? const {});
                    final auto = Map<String, dynamic>.from(
                        pref['autoClear'] as Map? ?? const {});
                    int? notiDays = (auto['notificationsDays'] as num?)?.toInt();
                    int? historyDays = (auto['historyDays'] as num?)?.toInt();
                    if (notiDays != null && (notiDays < 1 || notiDays > 7)) {
                      notiDays = null;
                    }
                    if (historyDays != null &&
                        (historyDays < 1 || historyDays > 7)) {
                      historyDays = null;
                    }

                    return ListView(
                      padding: const EdgeInsets.all(14),
                      children: [
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Auto Clear',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 10),
                                DropdownButtonFormField<int?>(
                                  initialValue: notiDays,
                                  decoration: const InputDecoration(
                                    labelText:
                                        'Notifications auto-clear interval',
                                  ),
                                  items: options
                                      .map(
                                        (d) => DropdownMenuItem<int?>(
                                          value: d,
                                          child: Text(d == null
                                              ? 'Off'
                                              : 'Every $d day(s)'),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (v) async {
                                    try {
                                      await _runWithLoader(
                                          'Saving notification policy...', () {
                                        return _fs
                                            .collection('traffic_users')
                                            .doc(uid)
                                            .set({
                                          'preferences': {
                                            'autoClear': {
                                              'notificationsDays': v,
                                              'historyDays': historyDays,
                                              'updatedAt':
                                                  FieldValue.serverTimestamp(),
                                            }
                                          }
                                        }, SetOptions(merge: true));
                                      });
                                      if (!context.mounted) return;
                                      showSpotlightToast(
                                        context,
                                        'Notifications auto-clear updated.',
                                        success: true,
                                      );
                                    } catch (e) {
                                      if (!context.mounted) return;
                                      showSpotlightToast(
                                        context,
                                        'Save failed: $e',
                                        success: false,
                                      );
                                    }
                                  },
                                ),
                                const SizedBox(height: 10),
                                DropdownButtonFormField<int?>(
                                  initialValue: historyDays,
                                  decoration: const InputDecoration(
                                    labelText: 'History auto-clear interval',
                                  ),
                                  items: options
                                      .map(
                                        (d) => DropdownMenuItem<int?>(
                                          value: d,
                                          child: Text(d == null
                                              ? 'Off'
                                              : 'Every $d day(s)'),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (v) async {
                                    try {
                                      await _runWithLoader(
                                          'Saving history policy...', () {
                                        return _fs
                                            .collection('traffic_users')
                                            .doc(uid)
                                            .set({
                                          'preferences': {
                                            'autoClear': {
                                              'notificationsDays': notiDays,
                                              'historyDays': v,
                                              'updatedAt':
                                                  FieldValue.serverTimestamp(),
                                            }
                                          }
                                        }, SetOptions(merge: true));
                                      });
                                      if (!context.mounted) return;
                                      showSpotlightToast(
                                        context,
                                        'History auto-clear updated.',
                                        success: true,
                                      );
                                    } catch (e) {
                                      if (!context.mounted) return;
                                      showSpotlightToast(
                                        context,
                                        'Save failed: $e',
                                        success: false,
                                      );
                                    }
                                  },
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'Max interval is 7 days.',
                                  style: TextStyle(color: Colors.black54),
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
                                  'Quick Actions',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        onPressed: () async {
                                          try {
                                            final count = await _runWithLoader(
                                                'Clearing notifications...', () {
                                              return _deleteByUser(
                                                collection: 'user_notifications',
                                                uid: uid,
                                              );
                                            });
                                            if (!context.mounted) return;
                                            showSpotlightToast(
                                              context,
                                              'Cleared $count notification(s).',
                                              success: true,
                                            );
                                          } catch (e) {
                                            if (!context.mounted) return;
                                            showSpotlightToast(
                                              context,
                                              'Clear failed: $e',
                                              success: false,
                                            );
                                          }
                                        },
                                        icon:
                                            const Icon(Icons.delete_sweep_rounded),
                                        label:
                                            const Text('Clear Notifications'),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        onPressed: () async {
                                          try {
                                            final count = await _runWithLoader(
                                                'Clearing history...', () {
                                              return _deleteByUser(
                                                collection: 'card_transactions',
                                                uid: uid,
                                                excludeTypes: const [
                                                  'ride_payment',
                                                  'top_up',
                                                ],
                                              );
                                            });
                                            if (!context.mounted) return;
                                            showSpotlightToast(
                                              context,
                                              'Cleared $count history record(s).',
                                              success: true,
                                            );
                                          } catch (e) {
                                            if (!context.mounted) return;
                                            showSpotlightToast(
                                              context,
                                              'Clear failed: $e',
                                              success: false,
                                            );
                                          }
                                        },
                                        icon:
                                            const Icon(Icons.history_toggle_off),
                                        label: const Text('Clear History'),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                if (_loading)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Container(
                        color: const Color(0x66000000),
                        alignment: Alignment.center,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: const Color(0xE610172A),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.white24),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SpotlightLoader(size: 22),
                              SizedBox(width: 10),
                              Text(
                                'Applying...',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
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

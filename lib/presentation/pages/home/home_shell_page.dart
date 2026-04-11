import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
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
          const _ActivitiesTab(),
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
            icon: Icon(Icons.receipt_long_rounded),
            label: 'Activities',
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
                    decoration: const InputDecoration(labelText: 'Phone number'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    style: const TextStyle(color: Colors.white),
                    keyboardType: TextInputType.number,
                    onChanged: (v) => setM(() => fleetText = v),
                    decoration: const InputDecoration(labelText: 'Number of vehicles'),
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
                        icon: Icon(obscure ? Icons.visibility_off : Icons.visibility),
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
      await _callWithFreshAuth('submitAgencyApplicationV2', payload);
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
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 18),
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
                      icon: Icon(obscure ? Icons.visibility_off : Icons.visibility),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: pass.trim().isEmpty ? null : () => Navigator.pop(ctx, true),
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
      await _callWithFreshAuth('openAgencyByPasswordV2', {
        'agencyId': agencyId,
        'password': pass.trim(),
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
            tooltip: isSuperAdmin ? 'Open Super Admin Console' : 'Restricted View',
            onPressed: () async {
              if (!isSuperAdmin) {
                _toast('Restricted mode: super admins only.', success: true);
                return;
              }
              if (!mounted) return;
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SuperAdminConsolePage()),
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
      body: Column(
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
                    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                      stream: uid == null
                          ? const Stream.empty()
                          : _fs.collection('agency_members').doc(uid).snapshots(),
                      builder: (context, memberSnap) {
                        final member = memberSnap.data?.data() ?? const <String, dynamic>{};
                        final belongs =
                            '${member['agencyId'] ?? ''}'.trim() == d.id && member['active'] == true;
                        return Card(
                          margin: const EdgeInsets.only(bottom: 10),
                          child: ListTile(
                            leading: CircleAvatar(
                              child: Text(
                                (code.isNotEmpty ? code : name.substring(0, 1)).toUpperCase(),
                              ),
                            ),
                            title: Text(name),
                            subtitle: Text(belongs ? 'Owned / member agency' : 'Not joined'),
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
    );
  }
}

class _ActivitiesTab extends StatelessWidget {
  const _ActivitiesTab();

  @override
  Widget build(BuildContext context) {
    final fs = FirebaseFirestore.instance;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return Scaffold(
      appBar: AppBar(title: const Text('Activities')),
      body: uid == null
          ? const Center(child: Text('Sign in required.'))
          : ListView(
              padding: const EdgeInsets.all(14),
              children: [
                _ActivitySection(
                  title: 'Top Ups',
                  stream: fs
                      .collection('card_transactions')
                      .where('userId', isEqualTo: uid)
                      .limit(25)
                      .snapshots(),
                ),
                const SizedBox(height: 12),
                _ActivitySection(
                  title: 'Bookings',
                  stream: fs
                      .collection('bookings')
                      .where('userId', isEqualTo: uid)
                      .limit(25)
                      .snapshots(),
                ),
                const SizedBox(height: 12),
                _ActivitySection(
                  title: 'Actions',
                  stream: fs
                      .collection('admin_events')
                      .where('actorId', isEqualTo: uid)
                      .limit(25)
                      .snapshots(),
                ),
              ],
            ),
    );
  }
}

class _ActivitySection extends StatelessWidget {
  const _ActivitySection({
    required this.title,
    required this.stream,
  });

  final String title;
  final Stream<QuerySnapshot<Map<String, dynamic>>> stream;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: stream,
              builder: (context, snap) {
                if (snap.hasError) return Text('${snap.error}');
                if (!snap.hasData) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: LinearProgressIndicator(minHeight: 2),
                  );
                }
                final docs = snap.data!.docs;
                if (docs.isEmpty) return const Text('No records yet.');
                return Column(
                  children: docs.take(5).map((d) {
                    final m = d.data();
                    final ts = m['updatedAt'] ?? m['createdAt'] ?? m['timestamp'];
                    final when = ts is Timestamp ? ts.toDate().toLocal().toString() : '-';
                    final label = '${m['type'] ?? m['status'] ?? d.id}';
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(label),
                      subtitle: Text(when, maxLines: 1, overflow: TextOverflow.ellipsis),
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

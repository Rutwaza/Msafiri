import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
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
  late final TabController _tab = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _review({
    required String applicationId,
    required bool approve,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) return;
      final idToken = await user.getIdToken(true);
      await _fx.httpsCallable('reviewAgencyApplicationV2').call({
        'idToken': idToken,
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
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
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
                    helperText: 'Example: Remera, Rwamagana, Kayonza, Kibungo, Nyakarambi',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  style: const TextStyle(color: Colors.white),
                  keyboardType: TextInputType.number,
                  onChanged: (v) => setM(() => fareText = v),
                  decoration: const InputDecoration(labelText: 'Default fare (RWF)'),
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
    final user = _auth.currentUser;
    if (user == null) return;
    final idToken = await user.getIdToken(true);
    final stops = stopsCsv
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    try {
      await _fx.httpsCallable('createDirectionPairV2').call({
        'idToken': idToken,
        'corridorName': corridor.trim(),
        'stops': stops,
        'defaultFareRwf': int.tryParse(fareText.trim()) ?? 0,
      });
      if (!mounted) return;
      showSpotlightToast(context, 'Direction pair created.', success: true);
    } catch (e) {
      if (!mounted) return;
      showSpotlightToast(context, 'Create failed: $e', success: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Super Admin Console'),
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: 'Approvals'),
            Tab(text: 'Directions'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _fs
                .collection('agency_applications')
                .where('status', isEqualTo: 'pending')
                .orderBy('submittedAt', descending: true)
                .limit(100)
                .snapshots(),
            builder: (context, snap) {
              if (snap.hasError) return Center(child: Text('${snap.error}'));
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              final docs = snap.data!.docs;
              if (docs.isEmpty) return const Center(child: Text('No pending applications.'));
              return ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: docs.length,
                itemBuilder: (context, i) {
                  final d = docs[i];
                  final m = d.data();
                  return Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: ListTile(
                      title: Text('${m['agencyName'] ?? 'Agency'}'),
                      subtitle: Text('Phone: ${m['phone'] ?? '-'} - Fleet: ${m['fleetSize'] ?? '-'}'),
                      trailing: Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton(
                            onPressed: () => _review(applicationId: d.id, approve: false),
                            child: const Text('Reject'),
                          ),
                          FilledButton(
                            onPressed: () => _review(applicationId: d.id, approve: true),
                            child: const Text('Approve'),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
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
                      'Agency admins assign directions to buses and set segment fares.',
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
                    if (snap.hasError) return Center(child: Text('${snap.error}'));
                    if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                    final docs = snap.data!.docs;
                    if (docs.isEmpty) return const Center(child: Text('No directions yet.'));
                    return ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: docs.length,
                      itemBuilder: (context, i) {
                        final d = docs[i];
                        final m = d.data();
                        final stops = (m['stopNames'] as List<dynamic>? ?? const [])
                            .map((e) => '$e')
                            .toList();
                        return Card(
                          margin: const EdgeInsets.only(bottom: 10),
                          child: ListTile(
                            title: Text('${m['corridorName'] ?? 'Corridor'} (${m['directionLabel'] ?? ''})'),
                            subtitle: Text('ID: ${d.id}\nStops: ${stops.join(' -> ')}'),
                            isThreeLine: true,
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

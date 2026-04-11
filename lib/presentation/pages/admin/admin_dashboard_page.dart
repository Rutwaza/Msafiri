import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/widgets/spotlight_toast.dart';

class AdminDashboardPage extends StatefulWidget {
  const AdminDashboardPage({super.key});

  @override
  State<AdminDashboardPage> createState() => _AdminDashboardPageState();
}

class _AdminDashboardPageState extends State<AdminDashboardPage>
    with SingleTickerProviderStateMixin {
  static const _tabs = ['Overview', 'Directions', 'Fleet', 'Cards', 'Activity', 'Bookings'];
  static const _superAdminEmail = 'nelsonjembe99@gmail.com';

  late TabController _tabController;
  final _fx = FirebaseFunctions.instanceFor(region: 'us-central1');
  final _fs = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;
  final _superEntityIdCtrl = TextEditingController();
  final _superExportIdCtrl = TextEditingController();
  final _superExportSearchCtrl = TextEditingController();
  final _superControlSearchCtrl = TextEditingController();

  String? _agencyId;
  String? _role;
  String? _error;
  bool _isSuperAdmin = false;
  bool _enterConsole = false;
  bool _loading = true;
  bool _countsLoading = false;
  Map<String, dynamic>? _systemCounts;
  Map<String, dynamic>? _systemFinance;
  String _exportResult = '';
  String _superEntityType = 'user';
  bool _superEntityActive = false;
  String _superExportType = 'user';
  String _superExportFormat = 'json';
  String _superExportSearch = '';
  String _superControlSearch = '';
  String? _softNotice;

  @override
  void initState() {
    super.initState();
    _createTabController();
    _loadMembership();
  }

  void _createTabController({int? initialIndex}) {
    final safeIndex = (initialIndex ?? 0).clamp(0, _tabs.length - 1);
    _tabController = TabController(length: _tabs.length, vsync: this, initialIndex: safeIndex);
    _tabController.addListener(() {
      if (!mounted) return;
      final maxIndex = _tabs.length - 1;
      if (_tabController.index > maxIndex && maxIndex >= 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _tabController.dispose();
          _createTabController(initialIndex: maxIndex);
          setState(() {});
        });
        return;
      }
      setState(() {});
    });
  }

  @override
  void reassemble() {
    super.reassemble();
    final oldIndex = _tabController.index;
    _tabController.dispose();
    _createTabController(initialIndex: oldIndex);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _superEntityIdCtrl.dispose();
    _superExportIdCtrl.dispose();
    _superExportSearchCtrl.dispose();
    _superControlSearchCtrl.dispose();
    super.dispose();
  }

  bool get _isAgencyAdmin => _role == 'agency_admin';
  bool get _canAssignRoutes =>
      _role == 'agency_admin' || _role == 'agency_staff';

  String _norm(String? value) => (value ?? '').trim().toLowerCase();

  bool _belongsToAgencyDoc(String docId, Map<String, dynamic> agencyData) {
    final mine = _norm(_agencyId);
    if (mine.isEmpty) return false;
    final byId = _norm(docId);
    final byName = _norm('${agencyData['name'] ?? ''}');
    final byCode = _norm('${agencyData['code'] ?? ''}');
    return mine == byId || mine == byName || mine == byCode;
  }

  String _entityCollection(String entityType) {
    switch (entityType) {
      case 'agency':
        return 'agencies';
      case 'route':
        return 'routes';
      case 'bus':
        return 'buses';
      case 'card':
        return 'cards';
      case 'user':
      default:
        return 'users';
    }
  }

  String _entityLabel(String entityType, String id, Map<String, dynamic> m) {
    if (entityType == 'user') {
      final name = '${m['displayName'] ?? m['name'] ?? ''}'.trim();
      final email = '${m['email'] ?? ''}'.trim();
      if (name.isNotEmpty && email.isNotEmpty) return '$name - $email';
      if (name.isNotEmpty) return name;
      if (email.isNotEmpty) return email;
      return id;
    }
    if (entityType == 'route') {
      final origin = '${m['origin'] ?? ''}'.trim();
      final destination = '${m['destination'] ?? ''}'.trim();
      if (origin.isNotEmpty && destination.isNotEmpty) {
        return '$origin -> $destination';
      }
    }
    if (entityType == 'bus') {
      final plate = '${m['plateNumber'] ?? ''}'.trim();
      final agency = '${m['agencyName'] ?? ''}'.trim();
      if (agency.isNotEmpty && plate.isNotEmpty) return '$agency - $plate';
      if (plate.isNotEmpty) return plate;
    }
    if (entityType == 'card') {
      final owner = '${m['userDisplayName'] ?? m['ownerName'] ?? ''}'.trim();
      if (owner.isNotEmpty) return '$owner ($id)';
      return id;
    }
    final name = '${m['name'] ?? ''}'.trim();
    if (name.isNotEmpty) return name;
    return id;
  }

  String _shortAdminTag() {
    final user = _auth.currentUser;
    String raw = '';
    if ((user?.displayName ?? '').trim().isNotEmpty) {
      raw = user!.displayName!.trim();
    } else if ((user?.email ?? '').contains('@')) {
      raw = (user?.email ?? '').split('@').first.trim();
    } else {
      raw = (user?.uid ?? 'you').trim();
    }
    final compact = raw.replaceAll(RegExp(r'\s+'), '');
    if (compact.isEmpty) return 'you...';
    if (compact.length <= 3) return '$compact...';
    return '${compact.substring(0, 3)}...';
  }

  Future<void> _callAdminPhone(String phone) async {
    final clean = phone.trim();
    if (clean.isEmpty) return;
    final uri = Uri.parse('tel:$clean');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  bool _entityIsActive(String entityType, Map<String, dynamic> data) =>
      data['active'] != false && data['isActive'] != false;

  void _closeSheet<T>(BuildContext context, [T? result]) {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(result);
  }

  String _friendlyError(Object error, {String fallback = 'Something went wrong.'}) {
    if (error is FirebaseFunctionsException) {
      final code = error.code.toLowerCase();
      final details = (error.message ?? '').trim();
      if (code == 'not-found') return details.isNotEmpty ? details : 'Feature is not deployed yet.';
      if (code == 'permission-denied') return details.isNotEmpty ? details : 'You do not have permission for this action.';
      if (code == 'unauthenticated') {
        return details.isNotEmpty ? 'Please sign in again and retry. ($details)' : 'Please sign in again and retry.';
      }
      if (details.isNotEmpty) return details;
      return fallback;
    }
    final text = '$error'.replaceAll('\n', ' ').trim();
    if (text.isEmpty) return fallback;
    if (text.length > 140) return '${text.substring(0, 140)}...';
    return text;
  }

  void _showSnack(String message, {bool? isError}) {
    if (!mounted) return;
    final text = message.trim();
    final lower = text.toLowerCase();
    final errorLike = isError ??
        lower.contains('failed') ||
        lower.contains('error') ||
        lower.contains('denied') ||
        lower.contains('invalid') ||
        lower.contains('not found') ||
        lower.contains('permission') ||
        lower.contains('missing') ||
        lower.contains('could not');
    showSpotlightToast(
      context,
      text,
      success: !errorLike,
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 16),
    );
  }

  Future<void> _loadMembership() async {
    try {
      final user = _auth.currentUser;
      final uid = user?.uid;
      if (uid == null) {
        setState(() {
          _error = 'Sign in required.';
          _loading = false;
        });
        return;
      }

      final email = (user?.email ?? '').toLowerCase();
      if (email == _superAdminEmail) {
        setState(() {
          _isSuperAdmin = true;
          _error = null;
          _loading = false;
        });
        unawaited(_refreshSystemCounts());
        return;
      }

      final doc = await _fs.collection('agency_members').doc(uid).get();
      if (!doc.exists) {
        setState(() {
          _error = null;
          _agencyId = null;
          _role = null;
          _loading = false;
        });
        return;
      }

      final d = doc.data()!;
      if (d['active'] != true) {
        setState(() {
          _error = 'Agency access is inactive.';
          _loading = false;
        });
        return;
      }

      setState(() {
        _agencyId = '${d['agencyId'] ?? ''}'.trim();
        _role = '${d['role'] ?? ''}'.trim().toLowerCase();
        _error = null;
        _enterConsole = false;
        _loading = false;
      });
      unawaited(
        _fs.collection('users').doc(uid).set({
          'isOnline': true,
          'lastSeenAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true)),
      );
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _submitAgencyApplication() async {
    _showSnack('Agency registration is removed in v2 reset. New flow coming next.');
  }

  Future<void> _approveApplication(String id) async {
    _showSnack('Agency approval is removed in v2 reset.');
  }

  Future<void> _rejectApplication(String id) async {
    _showSnack('Agency approval is removed in v2 reset.');
  }

  Future<void> _resolveDirectionRequest({
    required String requestId,
    required bool approve,
    int? fareRwf,
  }) async {
    try {
      final callable = _fx.httpsCallable('resolveDirectionRequest');
      await callable.call({
        'requestId': requestId,
        'approve': approve,
        if (fareRwf != null) 'fareRwf': fareRwf,
      });
      _showSnack(approve ? 'Direction request approved.' : 'Direction request rejected.');
    } catch (e) {
      _showSnack('Direction request failed: ${_friendlyError(e)}');
    }
  }

  Future<void> _refreshSystemCounts() async {
    if (!_isSuperAdmin) return;
    setState(() => _countsLoading = true);
    try {
      final callable = _fx.httpsCallable('getSystemCounts');
      final res = await callable.call();
      final financeCallable = _fx.httpsCallable('getSystemFinanceBreakdown');
      final financeRes = await financeCallable.call();
      if (!mounted) return;
      final countsRaw = Map<String, dynamic>.from(res.data as Map);
      final totalsRaw = Map<String, dynamic>.from((countsRaw['totals'] as Map?) ?? const {});
      final activeRaw = Map<String, dynamic>.from((countsRaw['active'] as Map?) ?? const {});
      countsRaw['totals'] = {
        ...totalsRaw,
        'buses': totalsRaw['buses'] ?? totalsRaw['pages'] ?? 0,
        'routes': totalsRaw['routes'] ?? 0,
      };
      countsRaw['active'] = {
        ...activeRaw,
        'buses': activeRaw['buses'] ?? activeRaw['pages'] ?? 0,
        'routes': activeRaw['routes'] ?? 0,
      };
      setState(() {
        _systemCounts = countsRaw;
        _systemFinance = Map<String, dynamic>.from(financeRes.data as Map);
        _countsLoading = false;
        _softNotice = null;
      });
    } catch (e) {
      await _refreshSystemCountsFallback();
    }
  }

  Future<void> _refreshSystemCountsFallback() async {
    try {
      final users = await _fs.collection('users').count().get();
      final buses = await _fs.collection('buses').count().get();
      final routes = await _fs.collection('routes').count().get();
      final agencies = await _fs.collection('agencies').count().get();
      final inactiveUsers = await _fs.collection('users').where('isActive', isEqualTo: false).count().get();
      final activeBuses = await _fs.collection('buses').where('active', isEqualTo: true).count().get();
      final activeRoutes = await _fs.collection('routes').where('active', isEqualTo: true).count().get();
      final activeAgencies = await _fs.collection('agencies').where('active', isEqualTo: true).count().get();
      final totalUsers = users.count ?? 0;
      final inactiveUsersCount = inactiveUsers.count ?? 0;
      if (!mounted) return;
      setState(() {
        _systemCounts = {
          'totals': {
            'users': totalUsers,
            'buses': buses.count ?? 0,
            'routes': routes.count ?? 0,
            'agencies': agencies.count ?? 0,
          },
          'active': {
            'users': (totalUsers - inactiveUsersCount).clamp(0, totalUsers),
            'buses': activeBuses.count ?? 0,
            'routes': activeRoutes.count ?? 0,
            'agencies': activeAgencies.count ?? 0,
          },
          'money': {
            'paidBookings': 0,
            'totalFareRwf': 0,
            'totalSpotlightShareRwf': 0,
            'totalAgencyShareRwf': 0,
          },
          'spotlightBank': const {
            'accountName': '-',
            'bankName': '-',
            'accountNumber': '-',
          },
        };
        _countsLoading = false;
        _softNotice = 'Using fallback counts while finance functions deploy.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _countsLoading = false;
        _softNotice = 'System counts could not load right now.';
      });
    }
  }

  void _enterAgencyConsole(String agencyId, String role) {
    if (!mounted) return;
    setState(() {
      _agencyId = agencyId;
      _role = role.trim().toLowerCase();
      _error = null;
      _enterConsole = true;
    });
    unawaited(_syncAgencyBuses());
  }

  Future<void> _syncAgencyBuses() async {
    final aid = _agencyId;
    if (aid == null || aid.isEmpty) return;
    try {
      final callable = _fx.httpsCallable('backfillDiscoveredBuses');
      await callable.call({'agencyId': aid});
    } catch (_) {
      // Best-effort sync only; UI keeps working even if function isn't deployed.
    }
  }

  Future<void> _resolveResetRequest(String id, String status) async {
    try {
      final callable = _fx.httpsCallable('resolveAgencyPasswordReset');
      await callable.call({'requestId': id, 'status': status});
      _showSnack('Request marked $status.');
    } catch (e) {
      _showSnack('Resolve failed: $e');
    }
  }

  Future<void> _setEntityActiveControl({
    required String entityType,
    required String entityId,
    required bool active,
  }) async {
    try {
      final callable = _fx.httpsCallable('setEntityActive');
      await callable.call({
        'entityType': entityType,
        'entityId': entityId,
        'active': active,
      });
      if (entityType == 'agency') {
        final apps = await _fs
            .collection('agency_applications')
            .where('provisionedAgencyId', isEqualTo: entityId)
            .limit(1)
            .get();
        if (apps.docs.isNotEmpty) {
          await apps.docs.first.reference.set({
            'agencyActive': active,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        }
      }
      _showSnack('${entityType.toUpperCase()} updated.');
      await _refreshSystemCounts();
    } catch (e) {
      _showSnack('Update failed: $e');
    }
  }

  Future<void> _updateBank({
    required String scope,
    String? agencyId,
  }) async {
    String accountName = '';
    String bankName = '';
    String accountNumber = '';
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
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
                scope == 'spotlight' ? 'Update SpotLight Bank Account' : 'Update Agency Bank Account',
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              TextField(
                style: const TextStyle(color: Colors.white),
                onChanged: (v) => accountName = v,
                decoration: const InputDecoration(labelText: 'Account name'),
              ),
              const SizedBox(height: 8),
              TextField(
                style: const TextStyle(color: Colors.white),
                onChanged: (v) => bankName = v,
                decoration: const InputDecoration(labelText: 'Bank name'),
              ),
              const SizedBox(height: 8),
              TextField(
                style: const TextStyle(color: Colors.white),
                onChanged: (v) => accountNumber = v,
                decoration: const InputDecoration(labelText: 'Account number'),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => _closeSheet(ctx, true),
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true) return;
    try {
      final me = _auth.currentUser;
      if (me == null) {
        _showSnack('Bank update failed: Please sign in and try again.', isError: true);
        return;
      }
      await me.getIdToken(true);
      final callable = _fx.httpsCallable('updateBankAccounts');
      await callable.call({
        'scope': scope,
        if (agencyId != null && agencyId.isNotEmpty) 'agencyId': agencyId,
        'accountName': accountName.trim(),
        'bankName': bankName.trim(),
        'accountNumber': accountNumber.trim(),
      });
      _showSnack('Bank details updated.');
      if (_isSuperAdmin) {
        await _refreshSystemCounts();
      }
    } catch (e) {
      _showSnack('Bank update failed: ${_friendlyError(e)}');
    }
  }

  Future<void> _exportEntity({
    required String entityType,
    required String entityId,
    required String format,
  }) async {
    try {
      final callable = _fx.httpsCallable('exportEntityData');
      final res = await callable.call({
        'entityType': entityType,
        'entityId': entityId,
        'format': format,
      });
      final data = Map<String, dynamic>.from(res.data as Map);
      final filePath = await _saveExportToFile(
        filename: '${data['filename'] ?? 'export.txt'}',
        content: '${data['content'] ?? ''}',
      );
      if (!mounted) return;
      setState(() => _exportResult = '${data['content'] ?? ''}');
      _showSnack('Export saved: $filePath');
    } catch (e) {
      _showSnack('Export failed: $e');
    }
  }

  Future<String> _saveExportToFile({
    required String filename,
    required String content,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final safeName = filename
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .trim();
    final stamped = '${DateTime.now().millisecondsSinceEpoch}_$safeName';
    final file = File('${dir.path}/$stamped');
    await file.writeAsString(content, flush: true);
    return file.path;
  }

  Future<void> _openAgencyByPassword({
    required String agencyId,
  }) async {
    String enteredPassword = '';
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
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
                'Open Agency',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              const Text(
                'Enter this agency password (set by agency admin).',
                style: TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              TextField(
                obscureText: true,
                style: const TextStyle(color: Colors.white),
                onChanged: (v) => enteredPassword = v,
                decoration: const InputDecoration(labelText: 'Agency password'),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => _closeSheet(ctx, {'action': 'open'}),
                  child: const Text('Open'),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => _closeSheet(ctx, {'action': 'forgot'}),
                child: const Text('Forgot agency password?'),
              ),
            ],
          ),
        ),
      ),
    );
    final password = enteredPassword.trim();
    if (result == null) return;
    final action = '${result['action'] ?? ''}';
    if (action == 'forgot') {
      await _requestAgencyPasswordReset(agencyId);
      return;
    }
    if (password.isEmpty) return;

    try {
      final callable = _fx.httpsCallable('openAgencyByPassword');
      final res = await callable.call({
        'agencyId': agencyId,
        'password': password,
      });
      final data = Map<String, dynamic>.from(res.data as Map);
      if (!mounted) return;
      _enterAgencyConsole(
        '${data['agencyId'] ?? agencyId}',
        '${data['role'] ?? _role ?? ''}',
      );
      _showSnack('Agency opened successfully.');
    } catch (e) {
      _showSnack('Open failed: ${_friendlyError(e, fallback: 'Could not open agency.')}');
    }
  }

  Future<void> _requestAgencyPasswordReset(String agencyId) async {
    try {
      final callable = _fx.httpsCallable('requestAgencyPasswordReset');
      final res = await callable.call({'agencyId': agencyId});
      final data = Map<String, dynamic>.from(res.data as Map);
      if ((data['alreadyPending'] ?? false) == true) {
        _showSnack('A reset request is already pending. Super admin will contact you.');
      } else {
        _showSnack('Reset request sent to super admin (nelsonjembe99@gmail.com).');
      }
    } catch (e) {
      _showSnack('Reset request failed: ${_friendlyError(e)}');
    }
  }

  Future<void> _setAgencyPassword() async {
    if (!_isAgencyAdmin) return;
    String pass = '';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
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
                'Set Agency Password',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              const Text(
                'This password is required when opening your agency from the list.',
                style: TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              TextField(
                obscureText: true,
                style: const TextStyle(color: Colors.white),
                onChanged: (v) => pass = v,
                decoration: const InputDecoration(labelText: 'New agency password'),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () async {
                    final p = pass.trim();
                    if (p.length < 4) return;
                    try {
                      final callable = _fx.httpsCallable('setAgencyAccessPassword');
                      await callable.call({'password': p});
                      if (!ctx.mounted) return;
                      _closeSheet(ctx);
                      _showSnack('Agency password updated.');
                    } catch (e) {
                      _showSnack('Failed: $e');
                    }
                  },
                  child: const Text('Save Password'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openBusForm({String? busId, Map<String, dynamic>? existing}) async {
    String idText = busId ?? '';
    String agencyNameText = existing?['agencyName']?.toString() ?? '';
    String plateText = existing?['plateNumber']?.toString() ?? '';
    String capacityText = '${existing?['capacity'] ?? 30}';
    String seatsText = '${existing?['availableSeats'] ?? 0}';
    String secretText = '';
    String routeId = existing?['routeId']?.toString() ?? '';
    bool active = existing?['active'] != false;

    final routeSnap = await _fs
        .collection('routes')
        .where('global', isEqualTo: true)
        .where('active', isEqualTo: true)
        .get();
    final busSnap = await _fs
        .collection('buses')
        .where('agencyId', isEqualTo: _agencyId)
        .limit(200)
        .get();
    if (!mounted) return;
    final routes = routeSnap.docs;
    final discoveredBuses = busSnap.docs;

    await showModalBottomSheet<void>(
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
                  Text(
                    busId == null ? 'Add Bus' : 'Edit Bus',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (busId == null && discoveredBuses.isNotEmpty) ...[
                    DropdownButtonFormField<String>(
                      initialValue: idText.isEmpty ? null : idText,
                      dropdownColor: const Color(0xFF0F172A),
                      decoration: const InputDecoration(
                        labelText: 'Pick discovered bus (by name/plate)',
                      ),
                      items: discoveredBuses
                          .map(
                            (b) => DropdownMenuItem<String>(
                              value: b.id,
                              child: Text(
                                '${b.id} - ${b.data()['plateNumber'] ?? ''} - ${b.data()['agencyName'] ?? ''}',
                                style: const TextStyle(color: Colors.white),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v == null) return;
                        final matched = discoveredBuses.firstWhere((b) => b.id == v).data();
                        setM(() {
                          idText = v;
                          agencyNameText =
                              '${matched['agencyName'] ?? agencyNameText}'.trim();
                          plateText = '${matched['plateNumber'] ?? plateText}'.trim();
                          if ((matched['capacity'] ?? '').toString().isNotEmpty) {
                            capacityText = '${matched['capacity']}';
                          }
                          if ((matched['availableSeats'] ?? '').toString().isNotEmpty) {
                            seatsText = '${matched['availableSeats']}';
                          }
                          if ((matched['routeId'] ?? '').toString().isNotEmpty) {
                            routeId = '${matched['routeId']}';
                          }
                          if (matched['active'] is bool) {
                            active = matched['active'] as bool;
                          }
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                  ],
                  TextFormField(
                    initialValue: idText,
                    enabled: busId == null,
                    style: const TextStyle(color: Colors.white),
                    onChanged: (v) => setM(() => idText = v),
                    decoration: const InputDecoration(labelText: 'Bus ID (matches device key)'),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    initialValue: agencyNameText,
                    style: const TextStyle(color: Colors.white),
                    onChanged: (v) => setM(() => agencyNameText = v),
                    decoration: const InputDecoration(labelText: 'Agency display name'),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    initialValue: plateText,
                    style: const TextStyle(color: Colors.white),
                    onChanged: (v) => setM(() => plateText = v),
                    decoration: const InputDecoration(labelText: 'Plate number'),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: routeId.isEmpty ? null : routeId,
                    dropdownColor: const Color(0xFF0F172A),
                    decoration: const InputDecoration(labelText: 'Route'),
                    items: routes
                        .map((r) => DropdownMenuItem<String>(
                              value: r.id,
                              child: Text(
                                '${r.data()['origin']} -> ${r.data()['destination']}',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ))
                        .toList(),
                    onChanged: (v) => setM(() => routeId = v ?? ''),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    initialValue: capacityText,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: Colors.white),
                    onChanged: (v) => setM(() => capacityText = v),
                    decoration: const InputDecoration(labelText: 'Capacity'),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    initialValue: seatsText,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: Colors.white),
                    onChanged: (v) => setM(() => seatsText = v),
                    decoration: const InputDecoration(labelText: 'Available seats'),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    style: const TextStyle(color: Colors.white),
                    onChanged: (v) => setM(() => secretText = v),
                    decoration: const InputDecoration(
                      labelText: 'Device secret (optional for update)',
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    value: active,
                    title: const Text('Active', style: TextStyle(color: Colors.white)),
                    onChanged: (v) => setM(() => active = v),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () async {
                        final cap = int.tryParse(capacityText.trim());
                        final seats = int.tryParse(seatsText.trim());
                        final finalBusId = idText.trim();
                        if (finalBusId.isEmpty || cap == null || seats == null) return;
                        try {
                          final callable = _fx.httpsCallable('createOrUpdateBus');
                          await callable.call({
                            'busId': finalBusId,
                            'agencyName': agencyNameText.trim(),
                            'plateNumber': plateText.trim(),
                            'routeId': routeId,
                            'capacity': cap,
                            'availableSeats': seats,
                            'active': active,
                            if (secretText.trim().isNotEmpty) 'deviceSecret': secretText.trim(),
                          });
                          if (!ctx.mounted) return;
                          Navigator.pop(ctx);
                          _showSnack('Bus saved.');
                        } catch (e) {
                          if (!ctx.mounted) return;
                          _showSnack('Bus save failed: $e', isError: true);
                        }
                      },
                      child: Text(busId == null ? 'Create Bus' : 'Save Bus'),
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

  Future<void> _openRouteForm({String? routeId, Map<String, dynamic>? existing}) async {
    _showSnack('Route creation/edit is removed in v2 reset.');
  }

  Future<void> _assignRouteToBus(String busId, String routeId) async {
    try {
      final callable = _fx.httpsCallable('assignRouteToBus');
      await callable.call({'busId': busId, 'routeId': routeId});
      _showSnack('Route assigned successfully.');
    } catch (e) {
      _showSnack('Assign failed: $e');
    }
  }

  Future<void> _topUpCard() async {
    String search = '';
    String? selectedCardId;
    String selectedCardLabel = '';
    String amountText = '';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: StatefulBuilder(
          builder: (ctx, setM) => Padding(
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
                  'Top Up Card Balance',
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                TextField(
                  style: const TextStyle(color: Colors.white),
                  onChanged: (v) => setM(() => search = v.trim().toLowerCase()),
                  decoration: const InputDecoration(
                    labelText: 'Search card (owner / card id)',
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 170,
                  child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: _fs.collection('cards').limit(200).snapshots(),
                    builder: (context, snap) {
                      if (snap.hasError) {
                        return Center(
                          child: Text(
                            'Could not load cards. ${_friendlyError(snap.error!)}',
                            style: const TextStyle(color: Colors.white70),
                            textAlign: TextAlign.center,
                          ),
                        );
                      }
                      if (!snap.hasData) {
                        return const Center(child: CircularProgressIndicator(strokeWidth: 2));
                      }
                      final docs = snap.data!.docs.where((d) {
                        final m = d.data();
                        if (m['active'] != true) return false;
                        if (search.isEmpty) return true;
                        final owner = '${m['ownerName'] ?? m['userId'] ?? ''}'.toLowerCase();
                        final cardId = d.id.toLowerCase();
                        return owner.contains(search) || cardId.contains(search);
                      }).toList();
                      if (docs.isEmpty) {
                        return const Center(
                          child: Text('No active cards found.', style: TextStyle(color: Colors.white70)),
                        );
                      }
                      return ListView.builder(
                        itemCount: docs.length,
                        itemBuilder: (_, i) {
                          final d = docs[i];
                          final m = d.data();
                          final owner = '${m['ownerName'] ?? m['userId'] ?? 'Unknown'}';
                          final label = '$owner - ${d.id} - RWF ${m['balanceRwf'] ?? 0}';
                          final active = selectedCardId == d.id;
                          return ListTile(
                            dense: true,
                            title: Text(
                              label,
                              style: TextStyle(
                                color: active ? const Color(0xFF93C5FD) : Colors.white,
                                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                              ),
                            ),
                            onTap: () {
                              setM(() {
                                selectedCardId = d.id;
                                selectedCardLabel = label;
                              });
                            },
                          );
                        },
                      );
                    },
                  ),
                ),
                if (selectedCardId != null) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Selected: $selectedCardLabel',
                      style: const TextStyle(color: Color(0xFF93C5FD), fontSize: 12),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                TextField(
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Colors.white),
                  onChanged: (v) => amountText = v,
                  decoration: const InputDecoration(labelText: 'Amount (RWF)'),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () async {
                      final amount = int.tryParse(amountText.trim());
                      if (selectedCardId == null || amount == null || amount <= 0) {
                        return;
                      }
                      try {
                        final callable = _fx.httpsCallable('topUpCard');
                        final res = await callable.call({
                          'cardId': selectedCardId,
                          'amountRwf': amount,
                        });
                        final data = Map<String, dynamic>.from(res.data as Map);
                        if (!ctx.mounted) return;
                        FocusManager.instance.primaryFocus?.unfocus();
                        Navigator.pop(ctx);
                        _showSnack('Top up success. New balance: RWF ${data['newBalanceRwf']}');
                      } catch (e) {
                        _showSnack('Top up failed: ${_friendlyError(e)}');
                      }
                    },
                    child: const Text('Top up'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _unassignRouteFromBus(String busId, String routeId) async {
    try {
      final callable = _fx.httpsCallable('unassignRouteFromBus');
      await callable.call({'busId': busId, 'routeId': routeId});
      _showSnack('Route unassigned successfully.');
    } catch (e) {
      _showSnack('Unassign failed: ${_friendlyError(e)}', isError: true);
    }
  }

  Future<void> _deleteRoute(String routeId, String label) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Direction'),
        content: Text('Delete "$label"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final callable = _fx.httpsCallable('deleteRoute');
      await callable.call({'routeId': routeId});
      _showSnack('Direction deleted.');
    } catch (e) {
      _showSnack('Delete failed: ${_friendlyError(e)}', isError: true);
    }
  }

  Future<void> _markBusTurnaround(String busId, {String? nextDirection}) async {
    try {
      final callable = _fx.httpsCallable('markBusTurnaround');
      await callable.call({
        'busId': busId,
        if (nextDirection != null && nextDirection.isNotEmpty) 'nextDirection': nextDirection,
      });
      _showSnack('Bus turnaround updated.');
    } catch (e) {
      _showSnack('Turnaround failed: ${_friendlyError(e)}', isError: true);
    }
  }

  Future<void> _releaseBookingSeat(String bookingId) async {
    try {
      final callable = _fx.httpsCallable('releaseBookingSeat');
      await callable.call({'bookingId': bookingId});
      _showSnack('Seat released successfully.');
    } catch (e) {
      _showSnack('Release failed: ${_friendlyError(e)}', isError: true);
    }
  }

  Future<void> _requestDirection() async {
    if (_role != 'agency_admin') return;
    String origin = '';
    String destination = '';
    String note = '';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
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
                'Request New Direction',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              TextField(
                style: const TextStyle(color: Colors.white),
                onChanged: (v) => origin = v,
                decoration: const InputDecoration(labelText: 'Origin'),
              ),
              const SizedBox(height: 8),
              TextField(
                style: const TextStyle(color: Colors.white),
                onChanged: (v) => destination = v,
                decoration: const InputDecoration(labelText: 'Destination'),
              ),
              const SizedBox(height: 8),
              TextField(
                style: const TextStyle(color: Colors.white),
                maxLines: 2,
                onChanged: (v) => note = v,
                decoration: const InputDecoration(labelText: 'Note (optional)'),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () async {
                    final o = origin.trim();
                    final d = destination.trim();
                    if (o.isEmpty || d.isEmpty) return;
                    try {
                      final callable = _fx.httpsCallable('requestDirection');
                      await callable.call({
                        'origin': o,
                        'destination': d,
                        'note': note.trim(),
                      });
                      if (!ctx.mounted) return;
                      _closeSheet(ctx);
                      _showSnack('Direction request sent to super admin.');
                    } catch (e) {
                      if (!ctx.mounted) return;
                      _showSnack('Request failed: ${_friendlyError(e)}', isError: true);
                    }
                  },
                  child: const Text('Send Request'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _setCardActive({
    required String cardId,
    required bool active,
  }) async {
    try {
      final callable = _fx.httpsCallable('setCardActive');
      await callable.call({
        'cardId': cardId,
        'active': active,
      });
      _showSnack(active ? 'Card reactivated.' : 'Card cut (disabled).');
    } catch (e) {
      _showSnack('Card update failed: ${_friendlyError(e)}');
    }
  }

  Future<void> _assignStaffRole() async {
    if (_role != 'agency_admin') return;
    String search = '';
    String selectedUid = '';
    String selectedEmail = '';
    String selectedName = '';

    await showModalBottomSheet<void>(
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
                const Text(
                  'Assign Agency Staff',
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Search users and pick using email for accuracy.',
                  style: TextStyle(color: Colors.white70),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                TextField(
                  style: const TextStyle(color: Colors.white),
                  onChanged: (v) => setM(() => search = v.trim().toLowerCase()),
                  decoration: const InputDecoration(
                    labelText: 'Search by name / username / email',
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 220,
                  child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: _fs.collection('users').limit(250).snapshots(),
                    builder: (context, snap) {
                      if (!snap.hasData) {
                        return const Center(child: CircularProgressIndicator(strokeWidth: 2));
                      }
                      final docs = snap.data!.docs.where((d) {
                        if (d.id == _auth.currentUser?.uid) return false;
                        if (search.isEmpty) return true;
                        final m = d.data();
                        final name = '${m['displayName'] ?? m['name'] ?? ''}'.toLowerCase();
                        final username = '${m['username'] ?? ''}'.toLowerCase();
                        final email = '${m['email'] ?? ''}'.toLowerCase();
                        return name.contains(search) ||
                            username.contains(search) ||
                            email.contains(search);
                      }).toList();
                      if (docs.isEmpty) {
                        return const Center(child: Text('No matching users.'));
                      }
                      return ListView.builder(
                        itemCount: docs.length,
                        itemBuilder: (_, i) {
                          final d = docs[i];
                          final m = d.data();
                          final name = '${m['displayName'] ?? m['name'] ?? 'User'}';
                          final email = '${m['email'] ?? ''}';
                          final username = '${m['username'] ?? ''}';
                          final selected = selectedUid == d.id;
                          return ListTile(
                            dense: true,
                            selected: selected,
                            selectedTileColor: const Color(0xFF1E3A8A).withValues(alpha: 0.25),
                            title: Text(name),
                            subtitle: Text(
                              '${email.isNotEmpty ? email : 'No email'}${username.isNotEmpty ? ' - @$username' : ''}',
                              style: const TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                            trailing: selected
                                ? const Icon(Icons.check_circle_rounded, color: Color(0xFF93C5FD))
                                : null,
                            onTap: () {
                              setM(() {
                                selectedUid = d.id;
                                selectedEmail = email;
                                selectedName = name;
                              });
                            },
                          );
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 10),
                if (selectedUid.isNotEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Text(
                      'Selected: $selectedName${selectedEmail.isNotEmpty ? ' - $selectedEmail' : ''}',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: selectedUid.isEmpty
                        ? null
                        : () async {
                            try {
                              final callable = _fx.httpsCallable('assignAgencyStaffRole');
                              await callable.call({
                                'targetUid': selectedUid,
                                if (selectedEmail.isNotEmpty) 'targetEmail': selectedEmail,
                              });
                              if (!ctx.mounted) return;
                              _closeSheet(ctx);
                              _showSnack(
                                selectedEmail.isNotEmpty
                                    ? 'Assigned staff: $selectedName - $selectedEmail'
                                    : 'Assigned staff: $selectedName',
                              );
                            } catch (e) {
                              if (!ctx.mounted) return;
                              _showSnack('Assign failed: ${_friendlyError(e)}', isError: true);
                            }
                          },
                    icon: const Icon(Icons.person_add_alt_1_rounded),
                    label: const Text('Assign As Staff'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _registerCardToUser() async {
    String cardIdText = '';
    String balanceText = '0';
    String search = '';
    String? selectedUserId;
    String selectedUserLabel = '';

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: StatefulBuilder(
          builder: (ctx, setM) => Padding(
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
                  'Register Card To User',
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                TextField(
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Search user (name / username / email / uid)',
                  ),
                  onChanged: (v) => setM(() => search = v.trim().toLowerCase()),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 160,
                  child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: _fs.collection('users').limit(120).snapshots(),
                    builder: (context, snap) {
                      if (snap.hasError) {
                        return Center(
                          child: Text(
                            'Could not load users. ${_friendlyError(snap.error!)}',
                            style: const TextStyle(color: Colors.white70),
                            textAlign: TextAlign.center,
                          ),
                        );
                      }
                      if (!snap.hasData) {
                        return const Center(child: CircularProgressIndicator(strokeWidth: 2));
                      }
                      final q = search;
                      final docs = snap.data!.docs.where((d) {
                        if (q.isEmpty) return true;
                        final m = d.data();
                        final display = '${m['displayName'] ?? m['name'] ?? ''}'.toLowerCase();
                        final username = '${m['username'] ?? ''}'.toLowerCase();
                        final email = '${m['email'] ?? ''}'.toLowerCase();
                        final uid = d.id.toLowerCase();
                        return display.contains(q) ||
                            username.contains(q) ||
                            email.contains(q) ||
                            uid.contains(q);
                      }).toList();
                      if (docs.isEmpty) {
                        return const Center(child: Text('No users found.', style: TextStyle(color: Colors.white70)));
                      }
                      return ListView.builder(
                        itemCount: docs.length,
                        itemBuilder: (_, i) {
                          final d = docs[i];
                          final m = d.data();
                          final label = '${m['displayName'] ?? m['name'] ?? 'User'} - ${m['email'] ?? d.id}';
                          final active = selectedUserId == d.id;
                          return ListTile(
                            dense: true,
                            title: Text(
                              label,
                              style: TextStyle(
                                color: active ? const Color(0xFF93C5FD) : Colors.white,
                                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                              ),
                            ),
                            onTap: () {
                              setM(() {
                                selectedUserId = d.id;
                                selectedUserLabel = label;
                              });
                            },
                          );
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
                if (selectedUserId != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Selected: $selectedUserLabel',
                      style: const TextStyle(color: Color(0xFF93C5FD), fontSize: 12),
                    ),
                  ),
                const SizedBox(height: 8),
                TextField(
                  style: const TextStyle(color: Colors.white),
                  onChanged: (v) => cardIdText = v,
                  decoration: const InputDecoration(labelText: 'Card ID (RFID UID)'),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  initialValue: balanceText,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Colors.white),
                  onChanged: (v) => balanceText = v,
                  decoration: const InputDecoration(labelText: 'Initial balance (RWF)'),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () async {
                      final amount = int.tryParse(balanceText.trim()) ?? 0;
                      if (selectedUserId == null || cardIdText.trim().isEmpty || amount < 0) {
                        return;
                      }
                      try {
                        final callable = _fx.httpsCallable('registerCardToUser');
                        await callable.call({
                          'cardId': cardIdText.trim(),
                          'userId': selectedUserId,
                          'initialBalanceRwf': amount,
                          'active': true,
                        });
                        if (!ctx.mounted) return;
                        FocusManager.instance.primaryFocus?.unfocus();
                        Navigator.pop(ctx);
                        _showSnack('Card registered to user successfully.');
                      } catch (e) {
                        _showSnack('Card registration failed: ${_friendlyError(e)}');
                      }
                    },
                    icon: const Icon(Icons.credit_card_rounded),
                    label: const Text('Register Card'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_isSuperAdmin) {
      return _buildSuperAdminConsole();
    }
    if (_enterConsole && _agencyId != null && _error == null) {
      return _buildAgencyConsole();
    }
    return _buildAgencyAccessHub();
  }

  Widget _buildSuperAdminConsole() {
    final totals = Map<String, dynamic>.from(_systemCounts?['totals'] as Map? ?? {});
    final active = Map<String, dynamic>.from(_systemCounts?['active'] as Map? ?? {});

    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Super Admin Console'),
          actions: [
            IconButton(
              tooltip: 'Refresh counts',
              onPressed: _refreshSystemCounts,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Approvals'),
              Tab(text: 'Reset Queue'),
              Tab(text: 'Analytics'),
              Tab(text: 'Controls'),
              Tab(text: 'Exports'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _fs
                  .collection('agency_applications')
                  .orderBy('submittedAt', descending: true)
                  .limit(200)
                  .snapshots(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Could not load approvals: ${_friendlyError(snap.error ?? 'unknown error')}',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final docs = snap.data!.docs;
                return Column(
                  children: [
                    Container(
                      margin: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                        stream: _fs
                            .collection('routes')
                            .where('global', isEqualTo: true)
                            .orderBy('origin')
                            .limit(100)
                            .snapshots(),
                        builder: (context, routeSnap) {
                          final routeDocs = routeSnap.data?.docs ?? const [];
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Master Directions & Fares',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 8),
                              if (routeDocs.isEmpty)
                                const Text('No directions created yet.')
                              else
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: routeDocs.map((r) {
                                    final m = r.data();
                                    final label =
                                        '${m['origin'] ?? ''} -> ${m['destination'] ?? ''} - RWF ${m['fareRwf'] ?? 0}';
                                    return InputChip(
                                      label: Text(
                                        label,
                                      ),
                                      deleteIcon: const Icon(Icons.delete_outline_rounded, size: 18),
                                      onDeleted: () => _deleteRoute(r.id, label),
                                    );
                                  }).toList(),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                    Container(
                      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.03),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                        stream: _fs
                            .collection('direction_requests')
                            .where('status', isEqualTo: 'pending')
                            .orderBy('createdAt', descending: true)
                            .limit(60)
                            .snapshots(),
                        builder: (context, reqSnap) {
                          if (!reqSnap.hasData) {
                            return const Center(child: CircularProgressIndicator(strokeWidth: 2));
                          }
                          final reqDocs = reqSnap.data!.docs;
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Requested Directions',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 8),
                              if (reqDocs.isEmpty)
                                const Text('No pending direction requests.')
                              else
                                ...reqDocs.map((d) {
                                  final m = d.data();
                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(alpha: 0.04),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: Colors.white10),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '${m['origin'] ?? ''} -> ${m['destination'] ?? ''}',
                                          style: const TextStyle(fontWeight: FontWeight.w700),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          'Agency: ${m['agencyName'] ?? m['agencyId'] ?? ''} - ${m['requesterEmail'] ?? ''}',
                                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                                        ),
                                        if ('${m['note'] ?? ''}'.trim().isNotEmpty)
                                          Text(
                                            'Note: ${m['note']}',
                                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                                          ),
                                        const SizedBox(height: 6),
                                        Row(
                                          children: [
                                            OutlinedButton(
                                              onPressed: () => _resolveDirectionRequest(
                                                requestId: d.id,
                                                approve: false,
                                              ),
                                              child: const Text('Reject'),
                                            ),
                                            const SizedBox(width: 8),
                                            FilledButton(
                                              onPressed: () async {
                                                String fareText = '';
                                                final fare = await showModalBottomSheet<int>(
                                                  context: context,
                                                  backgroundColor: const Color(0xFF0F172A),
                                                  shape: const RoundedRectangleBorder(
                                                    borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
                                                  ),
                                                  builder: (sheetCtx) => StatefulBuilder(
                                                    builder: (sheetCtx, setM) => SafeArea(
                                                      child: Padding(
                                                        padding: EdgeInsets.only(
                                                          left: 16,
                                                          right: 16,
                                                          top: 16,
                                                          bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 16,
                                                        ),
                                                        child: Column(
                                                          mainAxisSize: MainAxisSize.min,
                                                          children: [
                                                            const Text(
                                                              'Set Fare (RWF)',
                                                              style: TextStyle(
                                                                color: Colors.white,
                                                                fontWeight: FontWeight.w700,
                                                                fontSize: 16,
                                                              ),
                                                            ),
                                                            const SizedBox(height: 10),
                                                            TextField(
                                                              style: const TextStyle(color: Colors.white),
                                                              keyboardType: TextInputType.number,
                                                              onChanged: (v) => setM(() => fareText = v),
                                                              decoration: const InputDecoration(labelText: 'Fare'),
                                                            ),
                                                            const SizedBox(height: 10),
                                                            SizedBox(
                                                              width: double.infinity,
                                                              child: FilledButton(
                                                                onPressed: () {
                                                                  final parsed = int.tryParse(fareText.trim());
                                                                  if (parsed == null || parsed < 0) return;
                                                                  Navigator.pop(sheetCtx, parsed);
                                                                },
                                                                child: const Text('Approve'),
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                );
                                                if (fare == null) return;
                                                await _resolveDirectionRequest(
                                                  requestId: d.id,
                                                  approve: true,
                                                  fareRwf: fare,
                                                );
                                              },
                                              child: const Text('Approve'),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  );
                                }),
                            ],
                          );
                        },
                      ),
                    ),
                    Expanded(
                      child: docs.isEmpty
                          ? const Center(child: Text('No applications yet.'))
                          : ListView.builder(
                              itemCount: docs.length,
                              itemBuilder: (context, i) {
                                final d = docs[i];
                                final m = d.data();
                                final contact = Map<String, dynamic>.from(m['contact'] as Map? ?? {});
                                final status = '${m['status'] ?? ''}';
                                final phone = '${contact['phone'] ?? ''}';
                                final provisionedAgencyId = '${m['provisionedAgencyId'] ?? ''}';
                                final agencyActive = (m['agencyActive'] ?? true) == true;
                                final actionButtons = <Widget>[];
                                if (status == 'pending' || status == 'under_review') {
                                  actionButtons.add(
                                    OutlinedButton(
                                      onPressed: () => _rejectApplication(d.id),
                                      child: const Text('Reject'),
                                    ),
                                  );
                                  actionButtons.add(
                                    FilledButton(
                                      onPressed: () => _approveApplication(d.id),
                                      child: const Text('Approve'),
                                    ),
                                  );
                                } else if (status == 'approved' && provisionedAgencyId.isNotEmpty) {
                                  actionButtons.add(
                                    OutlinedButton(
                                      onPressed: () => _setEntityActiveControl(
                                        entityType: 'agency',
                                        entityId: provisionedAgencyId,
                                        active: !agencyActive,
                                      ),
                                      child: Text(agencyActive ? 'Deactivate' : 'Reactivate'),
                                    ),
                                  );
                                  if (phone.trim().isNotEmpty) {
                                    actionButtons.add(
                                      IconButton(
                                        tooltip: 'Call admin',
                                        onPressed: () => _callAdminPhone(phone),
                                        icon: const Icon(Icons.call_rounded),
                                      ),
                                    );
                                  }
                                }
                                return Card(
                                  margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                                  child: ListTile(
                                    isThreeLine: true,
                                    title: Text('${m['agencyName'] ?? 'Agency'}'),
                                    subtitle: Text(
                                      '${contact['fullName'] ?? ''} - ${m['ownerEmail'] ?? ''}\n'
                                      'Fleet: ${m['fleetSize'] ?? 0} - Status: $status',
                                    ),
                                    trailing: actionButtons.isEmpty
                                        ? null
                                        : Wrap(spacing: 8, children: actionButtons),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                );
              },
            ),
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _fs
                  .collection('agency_password_reset_requests')
                  .orderBy('createdAt', descending: true)
                  .limit(200)
                  .snapshots(),
              builder: (context, snap) {
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final docs = snap.data!.docs;
                if (docs.isEmpty) return const Center(child: Text('No reset requests.'));
                return ListView.builder(
                  itemCount: docs.length,
                  itemBuilder: (context, i) {
                    final d = docs[i];
                    final m = d.data();
                    final status = '${m['status'] ?? ''}';
                    return Card(
                      margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      child: ListTile(
                        title: Text('Agency: ${m['agencyId'] ?? ''}'),
                        subtitle: Text(
                          'Requester: ${m['requesterEmail'] ?? m['requesterUid'] ?? ''}\nStatus: $status',
                        ),
                        isThreeLine: true,
                        trailing: status == 'pending'
                            ? Wrap(
                                spacing: 8,
                                children: [
                                  TextButton(
                                    onPressed: () => _resolveResetRequest(d.id, 'rejected'),
                                    child: const Text('Reject'),
                                  ),
                                  FilledButton(
                                    onPressed: () => _resolveResetRequest(d.id, 'resolved'),
                                    child: const Text('Resolve'),
                                  ),
                                ],
                              )
                            : Chip(label: Text(status)),
                      ),
                    );
                  },
                );
              },
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: _countsLoading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      children: [
                        if (_softNotice != null)
                          Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFF7C2D12).withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: const Color(0xFFF59E0B).withValues(alpha: 0.35),
                              ),
                            ),
                            child: Text(
                              _softNotice!,
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ),
                        Row(
                          children: [
                            Expanded(
                              child: _statCard(
                                'Users',
                                '${totals['users'] ?? 0}',
                                'Active: ${active['users'] ?? 0}',
                                Colors.blue,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _statCard(
                                'Buses',
                                '${totals['buses'] ?? 0}',
                                'Active: ${active['buses'] ?? 0}',
                                Colors.indigo,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _statCard(
                                'Routes',
                                '${totals['routes'] ?? 0}',
                                'Active: ${active['routes'] ?? 0}',
                                Colors.tealAccent,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.04),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'System Money Snapshot',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 8),
                              Text('Paid bookings: ${(_systemCounts?['money']?['paidBookings'] ?? 0)}'),
                              Text('Total fare: RWF ${(_systemCounts?['money']?['totalFareRwf'] ?? 0)}'),
                              Text('Agencies share: RWF ${(_systemCounts?['money']?['totalAgencyShareRwf'] ?? 0)}'),
                              Text('SpotLight share: RWF ${(_systemCounts?['money']?['totalSpotlightShareRwf'] ?? 0)}'),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  const Expanded(
                                    child: Text(
                                      'SpotLight Company Account',
                                      style: TextStyle(fontWeight: FontWeight.w700),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () => _updateBank(scope: 'spotlight'),
                                    child: const Text('Update'),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${_systemCounts?['spotlightBank']?['accountName'] ?? '-'}\n'
                                '${_systemCounts?['spotlightBank']?['bankName'] ?? '-'}\n'
                                '${_systemCounts?['spotlightBank']?['accountNumber'] ?? '-'}',
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        const Text(
                          'Finance Per Agency',
                          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                        ),
                        const SizedBox(height: 8),
                        Builder(
                          builder: (context) {
                            final list = (_systemFinance?['perAgency'] as List?) ?? const [];
                            if (list.isEmpty) {
                              return const Text('No per-agency finance data yet.');
                            }
                            return Column(
                              children: list.map((raw) {
                                final m = Map<String, dynamic>.from(raw as Map);
                                return Container(
                                  width: double.infinity,
                                  margin: const EdgeInsets.only(bottom: 8),
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.04),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: Colors.white12),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${m['agencyName'] ?? m['agencyId']}',
                                        style: const TextStyle(fontWeight: FontWeight.w700),
                                      ),
                                      const SizedBox(height: 4),
                                      Text('Total fare: RWF ${m['totalFareRwf'] ?? 0}'),
                                      Text('Agency share: RWF ${m['totalAgencyShareRwf'] ?? 0}'),
                                      Text('SpotLight share: RWF ${m['totalSpotlightShareRwf'] ?? 0}'),
                                    ],
                                  ),
                                );
                              }).toList(),
                            );
                          },
                        ),
                        const SizedBox(height: 14),
                        const Text(
                          'Registered Agency Bank Accounts',
                          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                        ),
                        const SizedBox(height: 8),
                        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                          stream: _fs.collection('agencies').orderBy('name').limit(200).snapshots(),
                          builder: (context, snap) {
                            if (!snap.hasData) {
                              return const Padding(
                                padding: EdgeInsets.all(12),
                                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                              );
                            }
                            final docs = snap.data!.docs;
                            if (docs.isEmpty) {
                              return const Text('No agencies registered yet.');
                            }
                            return Column(
                              children: docs.map((d) {
                                final m = d.data();
                                final name = '${m['name'] ?? d.id}';
                                final bankName = '${m['bankName'] ?? '-'}';
                                final accountName = '${m['bankAccountName'] ?? '-'}';
                                final accountNo = '${m['bankAccountNumber'] ?? '-'}';
                                return Container(
                                  width: double.infinity,
                                  margin: const EdgeInsets.only(bottom: 8),
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.04),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: Colors.white12),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              name,
                                              style: const TextStyle(fontWeight: FontWeight.w700),
                                            ),
                                          ),
                                          TextButton(
                                            onPressed: () => _updateBank(scope: 'agency', agencyId: d.id),
                                            child: const Text('Update'),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text('$accountName - $bankName'),
                                      Text(accountNo, style: const TextStyle(color: Colors.white70)),
                                    ],
                                  ),
                                );
                              }).toList(),
                            );
                          },
                        ),
                      ],
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => _openRouteForm(),
                      icon: const Icon(Icons.alt_route_rounded),
                      label: const Text('Create Master Direction'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Activate / Deactivate Entities',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: _superEntityType,
                    decoration: const InputDecoration(labelText: 'Entity type'),
                    items: const [
                      DropdownMenuItem(value: 'user', child: Text('User')),
                      DropdownMenuItem(value: 'agency', child: Text('Agency')),
                      DropdownMenuItem(value: 'route', child: Text('Route')),
                      DropdownMenuItem(value: 'bus', child: Text('Bus')),
                    ],
                    onChanged: (v) {
                      setState(() {
                        _superEntityType = v ?? 'user';
                        _superEntityIdCtrl.clear();
                        _superEntityActive = false;
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _superControlSearchCtrl,
                    decoration: const InputDecoration(labelText: 'Search by username/name/email'),
                    onChanged: (v) => setState(() => _superControlSearch = v.trim().toLowerCase()),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 170,
                    child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: _fs.collection(_entityCollection(_superEntityType)).limit(200).snapshots(),
                      builder: (context, snap) {
                        if (!snap.hasData) {
                          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
                        }
                        final docs = snap.data!.docs.where((d) {
                          if (_superControlSearch.isEmpty) return true;
                          final m = d.data();
                          final hay = [
                            _entityLabel(_superEntityType, d.id, m).toLowerCase(),
                            '${m['email'] ?? ''}'.toLowerCase(),
                            '${m['username'] ?? ''}'.toLowerCase(),
                          ].join(' ');
                          return hay.contains(_superControlSearch);
                        }).toList();
                        if (docs.isEmpty) {
                          return const Center(child: Text('No matching entities.'));
                        }
                        return ListView.builder(
                          itemCount: docs.length,
                          itemBuilder: (_, i) {
                            final d = docs[i];
                            final m = d.data();
                            final selected = _superEntityIdCtrl.text.trim() == d.id;
                            return ListTile(
                              dense: true,
                              title: Text(_entityLabel(_superEntityType, d.id, m)),
                              subtitle: Text(
                                '${m['email'] ?? m['username'] ?? d.id}',
                                style: const TextStyle(color: Colors.white70, fontSize: 12),
                              ),
                              trailing: selected
                                  ? const Icon(Icons.check_circle_rounded, color: Color(0xFF93C5FD))
                                  : null,
                              onTap: () => setState(() {
                                _superEntityIdCtrl.text = d.id;
                                _superEntityActive = _entityIsActive(_superEntityType, m);
                              }),
                            );
                          },
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    value: _superEntityActive,
                    contentPadding: EdgeInsets.zero,
                    title: Text(_superEntityActive ? 'Activate' : 'Deactivate'),
                    onChanged: (v) => setState(() => _superEntityActive = v),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () {
                        final id = _superEntityIdCtrl.text.trim();
                        if (id.isEmpty) return;
                        _setEntityActiveControl(
                          entityType: _superEntityType,
                          entityId: id,
                          active: _superEntityActive,
                        );
                      },
                      child: const Text('Apply'),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: ListView(
                children: [
                  const Text(
                    'Export Tools',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _superExportType,
                          decoration: const InputDecoration(labelText: 'Entity'),
                          items: const [
                            DropdownMenuItem(value: 'user', child: Text('User')),
                            DropdownMenuItem(value: 'agency', child: Text('Agency')),
                            DropdownMenuItem(value: 'route', child: Text('Route')),
                            DropdownMenuItem(value: 'bus', child: Text('Bus')),
                            DropdownMenuItem(value: 'card', child: Text('Card')),
                          ],
                          onChanged: (v) => setState(() => _superExportType = v ?? 'user'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _superExportFormat,
                          decoration: const InputDecoration(labelText: 'Format'),
                          items: const [
                            DropdownMenuItem(value: 'json', child: Text('JSON')),
                            DropdownMenuItem(value: 'csv', child: Text('CSV')),
                          ],
                          onChanged: (v) => setState(() => _superExportFormat = v ?? 'json'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _superExportSearchCtrl,
                    decoration: const InputDecoration(labelText: 'Search by name/email'),
                    onChanged: (v) => setState(() => _superExportSearch = v.trim().toLowerCase()),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 150,
                    child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: _fs.collection(_entityCollection(_superExportType)).limit(160).snapshots(),
                      builder: (context, snap) {
                        if (!snap.hasData) {
                          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
                        }
                        final docs = snap.data!.docs.where((d) {
                          if (_superExportSearch.isEmpty) return true;
                          final m = d.data();
                          final hay = [
                            _entityLabel(_superExportType, d.id, m).toLowerCase(),
                            '${m['email'] ?? ''}'.toLowerCase(),
                            '${m['username'] ?? ''}'.toLowerCase(),
                          ].join(' ');
                          return hay.contains(_superExportSearch);
                        }).toList();
                        if (docs.isEmpty) {
                          return const Center(child: Text('No matching records.'));
                        }
                        return ListView.builder(
                          itemCount: docs.length,
                          itemBuilder: (_, i) {
                            final d = docs[i];
                            final m = d.data();
                            final label = _entityLabel(_superExportType, d.id, m);
                            final selected = _superExportIdCtrl.text.trim() == d.id;
                            return ListTile(
                              dense: true,
                              title: Text(
                                label,
                                style: TextStyle(
                                  color: selected ? const Color(0xFF93C5FD) : Colors.white,
                                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                                ),
                              ),
                              subtitle: Text(
                                d.id,
                                style: const TextStyle(color: Colors.white54, fontSize: 12),
                              ),
                              onTap: () => setState(() => _superExportIdCtrl.text = d.id),
                            );
                          },
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () {
                        final id = _superExportIdCtrl.text.trim();
                        if (id.isEmpty) return;
                        _exportEntity(
                          entityType: _superExportType,
                          entityId: id,
                          format: _superExportFormat,
                        );
                      },
                      child: const Text('Export Entity'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(minHeight: 120, maxHeight: 220),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        _exportResult.isEmpty
                            ? 'Export output will appear here.'
                            : _exportResult,
                        style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statCard(String title, String value, String subtitle, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color.withValues(alpha: 0.22), color.withValues(alpha: 0.08)],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(subtitle, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildAgencyAccessHub() {
    return Scaffold(
      appBar: AppBar(title: const Text('Agency Console')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const SizedBox(height: 4),
            const Text(
              'Choose an agency mode',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
              Text(
                _error ??
                    (_agencyId == null
                        ? 'No agency access yet. Agency onboarding is being rebuilt in v2 reset.'
                        : 'You have agency access. Open console or switch workflow.'),
                textAlign: TextAlign.center,
              ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _submitAgencyApplication,
                icon: const Icon(Icons.block_rounded),
                label: const Text('Agency Registration (Resetting)'),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: _fs.collection('agencies').where('active', isEqualTo: true).limit(50).snapshots(),
                builder: (context, snap) {
                  if (snap.hasError) {
                    return Center(
                      child: Text(
                        _friendlyError(snap.error ?? 'Could not load agencies.'),
                        textAlign: TextAlign.center,
                      ),
                    );
                  }
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final docs = snap.data!.docs;
                  if (docs.isEmpty) {
                    return const Center(child: Text('No agencies listed yet.'));
                  }
                  return ListView.builder(
                    itemCount: docs.length,
                    itemBuilder: (context, i) {
                      final m = docs[i].data();
                      final name = '${m['name'] ?? 'Agency'}';
                      final code = '${m['code'] ?? ''}';
                      final belongs = _belongsToAgencyDoc(docs[i].id, m);
                      final canOpen = belongs;
                      final subtitleText = belongs
                          ? 'Registered agency - You: ${_shortAdminTag()}'
                          : 'Registered agency';
                      return Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: ListTile(
                          leading: CircleAvatar(
                            child: Text((code.isNotEmpty ? code : name.substring(0, 1)).toUpperCase()),
                          ),
                          title: Text(name),
                          subtitle: Text(subtitleText),
                            trailing: FilledButton(
                              onPressed: canOpen
                                  ? () => _openAgencyByPassword(
                                        agencyId: docs[i].id,
                                      )
                                  : null,
                              child: const Text('Open'),
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
      ),
    );
  }

  Widget _buildAgencyConsole() {
    if (_tabController.length != _tabs.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final old = _tabController.index;
        _tabController.dispose();
        _createTabController(initialIndex: old);
        setState(() {});
      });
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(_isAgencyAdmin ? 'Agency Admin Console' : 'Agency Staff Console'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => setState(() => _enterConsole = false),
        ),
        actions: [
          if (_isAgencyAdmin)
            IconButton(
              tooltip: 'Update agency bank account',
              onPressed: () => _updateBank(scope: 'agency'),
              icon: const Icon(Icons.account_balance_rounded),
            ),
          if (_isAgencyAdmin)
            IconButton(
              tooltip: 'Set agency password',
              onPressed: _setAgencyPassword,
              icon: const Icon(Icons.lock_reset_rounded),
            ),
          IconButton(
            tooltip: 'Sign out',
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              if (!context.mounted) return;
              context.go(AppRoutes.login);
            },
            icon: const Icon(Icons.logout_rounded),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(50),
          child: Container(
            margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white12),
            ),
            child: TabBar(
              controller: _tabController,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              indicatorSize: TabBarIndicatorSize.tab,
              indicator: BoxDecoration(
                color: const Color(0xFF1D4ED8).withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF60A5FA).withValues(alpha: 0.5)),
              ),
              labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
              unselectedLabelColor: Colors.white70,
              tabs: _tabs.map((t) => Tab(text: t)).toList(),
            ),
          ),
        ),
      ),
      floatingActionButton: _tabController.index == 0 && _isAgencyAdmin
          ? null
          : _tabController.index == 1 && _isAgencyAdmin
              ? null
          : _tabController.index == 2 && _isAgencyAdmin
              ? FloatingActionButton.extended(
                  onPressed: () => _openBusForm(),
                  label: const Text('Add Bus'),
                  icon: const Icon(Icons.directions_bus_rounded),
                )
          : _tabController.index == 3
              ? FloatingActionButton.extended(
                  onPressed: _topUpCard,
                  label: const Text('Top Up'),
                  icon: const Icon(Icons.account_balance_wallet_rounded),
                )
              : null,
      body: TabBarView(
        controller: _tabController,
        children: [
          _OverviewTab(
            agencyId: _agencyId!,
            role: _role ?? '',
            fx: _fx,
            currentUserId: _auth.currentUser?.uid ?? '',
          ),
          _RoutesTab(
            agencyId: _agencyId!,
            canEdit: false,
            canRequestDirection: _role == 'agency_admin',
            onEdit: _openRouteForm,
            onRequestDirection: _role == 'agency_admin' ? _requestDirection : null,
          ),
          _FleetTab(
            agencyId: _agencyId!,
            canAssign: _canAssignRoutes,
            onAssign: _assignRouteToBus,
            onUnassign: _unassignRouteFromBus,
            onTurnaround: _markBusTurnaround,
            onEditBus: _isAgencyAdmin ? _openBusForm : null,
          ),
          _TopUpTab(
            onRegisterCard: _registerCardToUser,
            onAssignStaff: _role == 'agency_admin' ? _assignStaffRole : null,
            onSetCardActive: _setCardActive,
            role: _role ?? '',
            agencyId: _agencyId!,
          ),
          _ActivityTab(agencyId: _agencyId!),
          _BookingsTab(
            agencyId: _agencyId!,
            onReleaseSeat: _releaseBookingSeat,
          ),
        ],
      ),
    );
  }
}

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({
    required this.agencyId,
    required this.role,
    required this.fx,
    required this.currentUserId,
  });

  final String agencyId;
  final String role;
  final FirebaseFunctions fx;
  final String currentUserId;

  bool get _isAdmin => role == 'agency_admin';

  Future<Map<String, dynamic>> _loadFinancials(FirebaseFirestore fs) async {
    try {
      final res = await fx.httpsCallable('getAgencyFinancialReport').call({'agencyId': agencyId});
      return Map<String, dynamic>.from(res.data as Map);
    } catch (_) {
      final paid = await fs
          .collection('bookings')
          .where('agencyId', isEqualTo: agencyId)
          .where('status', isEqualTo: 'paid')
          .get();
      int paidBookings = 0;
      int totalFare = 0;
      int totalAgencyShare = 0;
      int totalSpotlightShare = 0;
      for (final doc in paid.docs) {
        final m = doc.data();
        final fare = (m['fareRwf'] as num?)?.toInt() ?? 0;
        final agencyShare = (m['agencyShareRwf'] as num?)?.toInt();
        final spotlightShare = (m['spotlightShareRwf'] as num?)?.toInt();
        paidBookings += 1;
        totalFare += fare;
        totalSpotlightShare += spotlightShare ?? ((fare * 5) ~/ 100);
        totalAgencyShare += agencyShare ?? (fare - ((fare * 5) ~/ 100));
      }
      final agencyDoc = await fs.collection('agencies').doc(agencyId).get();
      final agency = agencyDoc.data() ?? {};
      return {
        'money': {
          'paidBookings': paidBookings,
          'totalFareRwf': totalFare,
          'totalAgencyShareRwf': totalAgencyShare,
          'totalSpotlightShareRwf': totalSpotlightShare,
        },
        'agencyBank': {
          'accountName': '${agency['bankAccountName'] ?? ''}',
          'bankName': '${agency['bankName'] ?? ''}',
          'accountNumber': '${agency['bankAccountNumber'] ?? ''}',
        },
      };
    }
  }

  bool _looksOnline(Map<String, dynamic> user, String uid) {
    if (uid == currentUserId) return true;
    if (user['isOnline'] == true) return true;
    final lastSeen = user['lastSeenAt'];
    if (lastSeen is Timestamp) {
      final diff = DateTime.now().difference(lastSeen.toDate());
      return diff.inMinutes <= 3;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final fs = FirebaseFirestore.instance;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        FutureBuilder<Map<String, dynamic>>(
          future: _loadFinancials(fs),
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.all(12),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              );
            }
            if (snap.hasError || !snap.hasData) {
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white12),
                ),
                child: const Text('Finance stats unavailable right now.'),
              );
            }
            final data = Map<String, dynamic>.from(snap.data!);
            final money = Map<String, dynamic>.from(data['money'] as Map? ?? {});
            final agencyBank = Map<String, dynamic>.from(data['agencyBank'] as Map? ?? {});
            return Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Agency Overview', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  const SizedBox(height: 8),
                  Text('Paid bookings: ${money['paidBookings'] ?? 0}'),
                  Text('Total fare: RWF ${money['totalFareRwf'] ?? 0}'),
                  Text('Agency share: RWF ${money['totalAgencyShareRwf'] ?? 0}'),
                  const SizedBox(height: 8),
                  const Text('Bank Account', style: TextStyle(fontWeight: FontWeight.w700)),
                  Text('${agencyBank['accountName'] ?? '-'}'),
                  Text('${agencyBank['bankName'] ?? '-'}'),
                  Text('${agencyBank['accountNumber'] ?? '-'}'),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 12),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: fs.collection('buses').where('agencyId', isEqualTo: agencyId).snapshots(),
          builder: (context, snap) {
            if (!snap.hasData) {
              return const SizedBox.shrink();
            }
            final docs = snap.data!.docs;
            final activeCount = docs.where((d) => d.data()['active'] == true).length;
            return Row(
              children: [
                Expanded(
                  child: _overviewCard(
                    title: 'Active Buses',
                    value: '$activeCount',
                    subtitle: 'of ${docs.length} total buses',
                    color: const Color(0xFF3B82F6),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _overviewCard(
                    title: 'Staff',
                    value: _isAdmin ? 'Live' : 'Members',
                    subtitle: _isAdmin ? 'online statuses' : 'read-only view',
                    color: const Color(0xFF14B8A6),
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 14),
        const Text('Agency Staff', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: 8),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: fs
              .collection('agency_members')
              .where('agencyId', isEqualTo: agencyId)
              .where('role', isEqualTo: 'agency_staff')
              .where('active', isEqualTo: true)
              .limit(200)
              .snapshots(),
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator(strokeWidth: 2));
            }
            final docs = snap.data!.docs;
            if (docs.isEmpty) {
              return const Text('No active staff yet.');
            }
            return Column(
              children: docs.map((d) {
                final uid = d.id;
                return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  future: fs.collection('users').doc(uid).get(),
                  builder: (context, userSnap) {
                    final m = userSnap.data?.data() ?? {};
                    final name = '${m['displayName'] ?? m['name'] ?? 'User'}';
                    final email = '${m['email'] ?? ''}';
                    final isOnline = _looksOnline(m, uid);
                    return Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.03),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isOnline ? const Color(0xFF22C55E) : const Color(0xFF9CA3AF),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
                                if (email.isNotEmpty)
                                  Text(
                                    email,
                                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                                  ),
                              ],
                            ),
                          ),
                          Text(
                            isOnline ? 'Online' : 'Offline',
                            style: TextStyle(
                              color: isOnline ? const Color(0xFF22C55E) : const Color(0xFF9CA3AF),
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              }).toList(),
            );
          },
        ),
      ],
    );
  }

  Widget _overviewCard({
    required String title,
    required String value,
    required String subtitle,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [color.withValues(alpha: 0.20), color.withValues(alpha: 0.06)]),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(subtitle, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      ),
    );
  }
}

class _RoutesTab extends StatelessWidget {
  const _RoutesTab({
    required this.agencyId,
    required this.canEdit,
    required this.canRequestDirection,
    required this.onEdit,
    this.onRequestDirection,
  });

  final String agencyId;
  final bool canEdit;
  final bool canRequestDirection;
  final Future<void> Function({String? routeId, Map<String, dynamic>? existing}) onEdit;
  final Future<void> Function()? onRequestDirection;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('routes')
          .where('global', isEqualTo: true)
          .where('active', isEqualTo: true)
          .snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final docs = snap.data!.docs;
        if (docs.isEmpty) return const Center(child: Text('No routes yet.'));
        return Column(
          children: [
            if (canRequestDirection)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: onRequestDirection,
                    icon: const Icon(Icons.add_road_rounded),
                    label: const Text('Request New Direction'),
                  ),
                ),
              ),
            Expanded(
              child: ListView.builder(
                itemCount: docs.length,
                itemBuilder: (context, i) {
                  final d = docs[i];
                  final m = d.data();
                  return ListTile(
                    title: Text('${m['origin']} -> ${m['destination']}'),
                    subtitle: Text('RWF ${m['fareRwf'] ?? 0}'),
                    trailing: canEdit
                        ? IconButton(
                            icon: const Icon(Icons.edit_rounded),
                            onPressed: () => onEdit(routeId: d.id, existing: m),
                          )
                        : null,
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _FleetTab extends StatelessWidget {
  const _FleetTab({
    required this.agencyId,
    required this.canAssign,
    required this.onAssign,
    required this.onUnassign,
    required this.onTurnaround,
    this.onEditBus,
  });

  final String agencyId;
  final bool canAssign;
  final Future<void> Function(String busId, String routeId) onAssign;
  final Future<void> Function(String busId, String routeId) onUnassign;
  final Future<void> Function(String busId, {String? nextDirection}) onTurnaround;
  final Future<void> Function({String? busId, Map<String, dynamic>? existing})? onEditBus;

  @override
  Widget build(BuildContext context) {
    final fs = FirebaseFirestore.instance;
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: fs.collection('buses').where('agencyId', isEqualTo: agencyId).snapshots(),
      builder: (context, busSnap) {
        if (!busSnap.hasData) return const Center(child: CircularProgressIndicator());
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: fs
              .collection('routes')
              .where('global', isEqualTo: true)
              .where('active', isEqualTo: true)
              .snapshots(),
          builder: (context, routeSnap) {
            if (!routeSnap.hasData) return const Center(child: CircularProgressIndicator());
            final routes = routeSnap.data!.docs;
            final routeLabels = {
              for (final r in routes)
                r.id: '${r.data()['origin'] ?? ''} -> ${r.data()['destination'] ?? ''}',
            };
            final routeFares = {
              for (final r in routes) r.id: (r.data()['fareRwf'] as num?)?.toInt() ?? 0,
            };
            final buses = busSnap.data!.docs;
            if (buses.isEmpty) return const Center(child: Text('No buses yet.'));
            return ListView.builder(
              itemCount: buses.length,
              itemBuilder: (context, i) {
                final b = buses[i];
                final m = b.data();
                final currentRoute = '${m['routeId'] ?? ''}';
                final currentRouteLabel = currentRoute.isEmpty
                    ? 'None'
                    : (routeLabels[currentRoute] ?? 'Unknown route');
                final extraRouteIds = (m['routeIds'] as List<dynamic>? ?? const [])
                    .map((e) => '$e')
                    .where((e) => e.trim().isNotEmpty)
                    .toList();
                final assignedRouteIds = {
                  if (currentRoute.isNotEmpty) currentRoute,
                  ...extraRouteIds,
                }.toList();
                final currentDirection = '${m['currentDirection'] ?? 'unknown'}';
                final tripCycle = (m['tripCycle'] as num?)?.toInt() ?? 0;

                return Container(
                  margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: const Color(0xFF2563EB).withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.directions_bus_rounded, color: Color(0xFF93C5FD)),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${m['plateNumber'] ?? b.id}',
                                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${m['agencyName'] ?? 'Bus'} - Seats ${m['availableSeats'] ?? 0}/${m['capacity'] ?? 0}',
                                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Primary: $currentRouteLabel',
                                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Direction: $currentDirection - Cycle #$tripCycle',
                                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                          if (canAssign)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Track on map',
                                  onPressed: () => context.push(
                                    '${AppRoutes.trafficManagement}?busId=${Uri.encodeComponent(b.id)}',
                                  ),
                                  icon: const Icon(Icons.location_on_rounded),
                                ),
                                PopupMenuButton<String>(
                                  tooltip: 'Assign route',
                                  onSelected: (rid) => onAssign(b.id, rid),
                                  itemBuilder: (context) => routes
                                      .map(
                                        (r) => PopupMenuItem<String>(
                                          value: r.id,
                                          child: Text(
                                            '${r['origin']} -> ${r['destination']} - RWF ${(r['fareRwf'] ?? 0)}',
                              ),
                            ),
                                      )
                                      .toList(),
                                ),
                                PopupMenuButton<String>(
                                  tooltip: 'Turnaround',
                                  onSelected: (v) {
                                    if (v == 'auto') {
                                      onTurnaround(b.id);
                                    } else {
                                      onTurnaround(b.id, nextDirection: v);
                                    }
                                  },
                                  itemBuilder: (context) => const [
                                    PopupMenuItem<String>(
                                      value: 'auto',
                                      child: Text('Turnaround (Auto Toggle)'),
                                    ),
                                    PopupMenuItem<String>(
                                      value: 'forward',
                                      child: Text('Set Direction: Forward'),
                                    ),
                                    PopupMenuItem<String>(
                                      value: 'reverse',
                                      child: Text('Set Direction: Reverse'),
                                    ),
                                  ],
                                  icon: const Icon(Icons.swap_horiz_rounded),
                                ),
                              ],
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (assignedRouteIds.isEmpty)
                        const Text('No assigned directions yet.', style: TextStyle(color: Colors.white60))
                      else
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: assignedRouteIds.map((rid) {
                            final label = routeLabels[rid] ?? rid;
                            final fare = routeFares[rid] ?? 0;
                            return Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(color: Colors.white12),
                              ),
                              child: Text(
                                '$label - RWF $fare',
                                style: const TextStyle(fontSize: 12),
                              ),
                            );
                          }).toList(),
                        ),
                      if (canAssign && assignedRouteIds.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: assignedRouteIds.map((rid) {
                            final label = routeLabels[rid] ?? rid;
                            return ActionChip(
                              avatar: const Icon(Icons.remove_circle_outline_rounded, size: 16),
                              label: Text('Unassign: $label', style: const TextStyle(fontSize: 12)),
                              onPressed: () => onUnassign(b.id, rid),
                            );
                          }).toList(),
                        ),
                      ],
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

class _TopUpTab extends StatelessWidget {
  const _TopUpTab({
    required this.onRegisterCard,
    this.onAssignStaff,
    required this.onSetCardActive,
    required this.role,
    required this.agencyId,
  });
  final Future<void> Function() onRegisterCard;
  final Future<void> Function()? onAssignStaff;
  final Future<void> Function({required String cardId, required bool active}) onSetCardActive;
  final String role;
  final String agencyId;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: onRegisterCard,
                icon: const Icon(Icons.badge_rounded),
                label: const Text('Register Card'),
              ),
              if (onAssignStaff != null)
                OutlinedButton.icon(
                  onPressed: onAssignStaff,
                  icon: const Icon(Icons.manage_accounts_rounded),
                  label: const Text('Assign Staff'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('Role: $role', style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('cards')
                  .where('issuerAgencyId', isEqualTo: agencyId)
                  .limit(120)
                  .snapshots(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(
                    child: Text(
                      'Could not load cards.\n${snap.error}',
                      style: const TextStyle(color: Colors.white70),
                      textAlign: TextAlign.center,
                    ),
                  );
                }
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final docs = [...snap.data!.docs]
                  ..sort((a, b) {
                    final at = (a.data()['updatedAt'] as Timestamp?)?.millisecondsSinceEpoch ?? 0;
                    final bt = (b.data()['updatedAt'] as Timestamp?)?.millisecondsSinceEpoch ?? 0;
                    return bt.compareTo(at);
                  });
                if (docs.isEmpty) {
                  return const Center(child: Text('No cards registered by this agency yet.'));
                }
                return ListView.builder(
                  itemCount: docs.length,
                  itemBuilder: (context, i) {
                    final d = docs[i].data();
                    final active = d['active'] == true;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.03),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.credit_card_rounded,
                                color: active ? const Color(0xFF22C55E) : const Color(0xFF9CA3AF),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Card ${docs[i].id}', style: const TextStyle(fontWeight: FontWeight.w700)),
                                    Text(
                                      'Owner: ${d['ownerName'] ?? d['userId'] ?? ''} - Balance: RWF ${d['balanceRwf'] ?? 0}',
                                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                              Chip(
                                label: Text(active ? 'Active' : 'Inactive'),
                                visualDensity: VisualDensity.compact,
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              OutlinedButton.icon(
                                onPressed: () => onSetCardActive(cardId: docs[i].id, active: !active),
                                icon: Icon(active ? Icons.cut_rounded : Icons.restart_alt_rounded),
                                label: Text(active ? 'Cut Card' : 'Reactivate'),
                              ),
                            ],
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
    );
  }
}

class _ActivityTab extends StatefulWidget {
  const _ActivityTab({required this.agencyId});
  final String agencyId;

  @override
  State<_ActivityTab> createState() => _ActivityTabState();
}

class _ActivityTabState extends State<_ActivityTab> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _search = '';
  String _category = 'all';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  bool _matchCategory(String type) {
    if (_category == 'all') return true;
    final t = type.toUpperCase();
    switch (_category) {
      case 'cards':
        return t.contains('CARD');
      case 'routes':
        return t.contains('ROUTE');
      case 'bus':
        return t.contains('BUS');
      case 'staff':
        return t.contains('STAFF');
      default:
        return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Column(
            children: [
              TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _search = v.trim().toLowerCase()),
                decoration: const InputDecoration(
                  labelText: 'Search activity (name, description, type)',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _catChip('all', 'All'),
                    _catChip('cards', 'Cards'),
                    _catChip('routes', 'Routes'),
                    _catChip('bus', 'Bus'),
                    _catChip('staff', 'Staff'),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('admin_events')
                .where('agencyId', isEqualTo: widget.agencyId)
                .orderBy('createdAt', descending: true)
                .limit(250)
                .snapshots(),
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(
                  child: Text(
                    'Could not load activity yet.\n${snap.error}',
                    style: const TextStyle(color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                );
              }
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              final docs = snap.data!.docs.where((doc) {
                final d = doc.data();
                final type = '${d['type'] ?? ''}';
                if (!_matchCategory(type)) return false;
                if (_search.isEmpty) return true;
                final hay = [
                  '${d['type'] ?? ''}'.toLowerCase(),
                  '${d['description'] ?? ''}'.toLowerCase(),
                  '${d['actorName'] ?? ''}'.toLowerCase(),
                  '${d['actorRole'] ?? ''}'.toLowerCase(),
                ].join(' ');
                return hay.contains(_search);
              }).toList();
              if (docs.isEmpty) return const Center(child: Text('No matching activity.'));
              return ListView.builder(
                itemCount: docs.length,
                itemBuilder: (context, i) {
                  final d = docs[i].data();
                  final actor = '${d['actorName'] ?? ''}'.trim().isNotEmpty
                      ? '${d['actorName']}'
                      : '${d['actorId'] ?? 'unknown'}';
                  final when = _timeAgoFromTs(d['createdAt'] as Timestamp?);
                  return Container(
                    margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.03),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('${d['type'] ?? 'Event'} - $actor'),
                      subtitle: Text('${d['description'] ?? ''}\n$when'),
                      isThreeLine: true,
                      trailing: Text('${d['actorRole'] ?? ''}'),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _catChip(String key, String label) {
    final selected = _category == key;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        selected: selected,
        label: Text(label),
        onSelected: (_) => setState(() => _category = key),
      ),
    );
  }

  String _timeAgoFromTs(Timestamp? ts) {
    if (ts == null) return 'now';
    final diff = DateTime.now().difference(ts.toDate());
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

class _BookingsTab extends StatelessWidget {
  const _BookingsTab({
    required this.agencyId,
    required this.onReleaseSeat,
  });
  final String agencyId;
  final Future<void> Function(String bookingId) onReleaseSeat;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('bookings')
          .where('agencyId', isEqualTo: agencyId)
          .orderBy('createdAt', descending: true)
          .limit(150)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
            child: Text(
              'Could not load bookings yet.\n${snap.error}',
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          );
        }
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final docs = snap.data!.docs;
        if (docs.isEmpty) return const Center(child: Text('No bookings yet.'));
        return ListView.builder(
          itemCount: docs.length,
          itemBuilder: (context, i) {
            final m = docs[i].data();
            final status = '${m['status'] ?? ''}';
            final rider = '${m['bookingUserName'] ?? m['userName'] ?? m['userId'] ?? ''}';
            final cardOwner = '${m['cardOwnerName'] ?? m['cardOwnerUid'] ?? rider}';
            final routeLabel = '${m['routeLabel'] ?? m['routeId'] ?? ''}';
            final busLabel = '${m['plateNumber'] ?? m['busId'] ?? ''}';
            final usedExternalCard = m['usedExternalCard'] == true;
            final seatReleased = m['seatReleased'] == true;
            final canRelease = (status == 'booked' || status == 'paid') && !seatReleased;
            final color = status == 'paid'
                ? const Color(0xFF22C55E)
                : status == 'booked'
                    ? const Color(0xFF3B82F6)
                    : status == 'expired'
                        ? const Color(0xFFF59E0B)
                        : const Color(0xFF9CA3AF);
            return Card(
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: ListTile(
                title: Text('Bus $busLabel - Seat ${m['seatNo'] ?? '-'}'),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Rider: $rider${usedExternalCard ? ' (other card)' : ''}\n'
                      'Card owner: $cardOwner - Card: ${m['cardId'] ?? ''}\n'
                      'Route: $routeLabel - Fare: RWF ${m['fareRwf'] ?? 0}',
                    ),
                    const SizedBox(height: 8),
                    if (seatReleased)
                      const Text(
                        'Seat released',
                        style: TextStyle(
                          color: Color(0xFF10B981),
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    if (canRelease)
                      OutlinedButton.icon(
                        onPressed: () => onReleaseSeat(docs[i].id),
                        icon: const Icon(Icons.event_seat_rounded),
                        label: const Text('Release Seat'),
                      ),
                  ],
                ),
                isThreeLine: true,
                trailing: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: color.withValues(alpha: 0.42)),
                  ),
                  child: Text(
                    status.toUpperCase(),
                    style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import 'local_database.dart';

/// Persistent local source of truth for data that the client can safely cache.
///
/// Sets are optimistically persisted into a small operation queue. The server's
/// /v1/sync endpoint is idempotent, so retrying an operation after an app crash
/// is safe.
class TrainingRepository extends ChangeNotifier {
  TrainingRepository._(
    this._preferences,
    this._database, {
    http.Client? client,
    FlutterSecureStorage? secureStorage,
  }) : _client = client ?? http.Client(),
       _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8000',
  );
  static const _accessTokenKey = 'access_token';
  static const _refreshTokenKey = 'refresh_token';
  static const _rememberedEmailKey = 'remembered_login_email';
  static const _rememberedPasswordKey = 'remembered_login_password';
  static const _deviceIdKey = 'device_id';
  static const _accountScopeKey = 'active_account_scope';
  static const _queueKey = 'sync_queue_v1';
  static const _syncCursorKey = 'sync_cursor_v1';
  static const _offlineWorkoutKey = 'offline_workout_v1';
  static const _rememberedAccountScopeKey = 'remembered_account_scope';

  final SharedPreferences _preferences;
  final LocalDatabase _database;
  final http.Client _client;
  final FlutterSecureStorage _secureStorage;
  Future<bool>? _refreshInFlight;

  bool isSignedIn = false;
  bool isOnline = true;
  bool isSyncing = false;
  bool isOwner = false;
  String? email;
  int attentionCount = 0;
  bool? _registrationEnabled;
  int pendingOperationCount = 0;
  String? lastSyncMessage;
  late String deviceId;
  String _accountScope = LocalDatabase.localScope;
  String? _rememberedAccountScope;

  static Future<TrainingRepository> create({
    http.Client? client,
    FlutterSecureStorage? secureStorage,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final repository = TrainingRepository._(
      preferences,
      await LocalDatabase.open(preferences),
      client: client,
      secureStorage: secureStorage,
    );
    await repository._restore();
    return repository;
  }

  Future<void> _restore() async {
    deviceId = _preferences.getString(_deviceIdKey) ?? _newUuid();
    await _preferences.setString(_deviceIdKey, deviceId);
    isSignedIn = await _secureStorage.read(key: _accessTokenKey) != null;
    _accountScope = await _secureStorage.read(key: _accountScopeKey) ?? LocalDatabase.localScope;
    _rememberedAccountScope = _preferences.getString(_rememberedAccountScopeKey);
    pendingOperationCount = await _database.outstandingOperationCount(_accountScope);
    attentionCount = await _database.attentionOperationCount(_accountScope);
    if (isSignedIn) await _loadMe();
  }

  Future<void> signIn({required String email, required String password}) async {
    final response = await _client.post(
      Uri.parse('$_baseUrl/v1/auth/login'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email.trim(),
        'password': password,
        'device_id': deviceId,
        'device_name': defaultTargetPlatform == TargetPlatform.windows
            ? 'Windows 桌面端'
            : 'iOS 客户端',
        'platform': defaultTargetPlatform == TargetPlatform.windows
            ? 'windows'
            : 'ios',
      }),
    );
    if (response.statusCode != 200) {
      throw ApiException(response.statusCode, response.body);
    }
    await _storeSession(jsonDecode(response.body) as Map<String, dynamic>);
    _accountScope = _accountScopeForEmail(email);
    await _secureStorage.write(key: _accountScopeKey, value: _accountScope);
    await _preferences.remove(_rememberedAccountScopeKey);
    _rememberedAccountScope = null;
    await _database.mergeLocalIntoAccount(_accountScope);
    pendingOperationCount = await _database.outstandingOperationCount(_accountScope);
    attentionCount = await _database.attentionOperationCount(_accountScope);
    isOnline = true;
    isSignedIn = true;
    await _loadMe();
    notifyListeners();
    // Upload the signed-out workspace, then show the freshly merged plans.
    await flushQueue();
    await loadPlans();
  }

  /// Creates a regular account on servers that enable self-service
  /// registration, then signs this device in immediately.
  Future<void> register({
    required String email,
    required String password,
    String displayName = '训练者',
  }) async {
    final response = await _client.post(
      Uri.parse('$_baseUrl/v1/auth/register'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email.trim(),
        'password': password,
        'display_name': displayName.trim().isEmpty ? '训练者' : displayName.trim(),
        'device_id': deviceId,
        'device_name': defaultTargetPlatform == TargetPlatform.windows ? 'Windows 桌面端' : 'iOS 客户端',
        'platform': defaultTargetPlatform == TargetPlatform.windows ? 'windows' : 'ios',
      }),
    );
    if (response.statusCode != 201 && response.statusCode != 200) {
      throw ApiException(response.statusCode, response.body);
    }
    await _storeSession(jsonDecode(response.body) as Map<String, dynamic>);
    _accountScope = _accountScopeForEmail(email);
    await _secureStorage.write(key: _accountScopeKey, value: _accountScope);
    await _preferences.remove(_rememberedAccountScopeKey);
    _rememberedAccountScope = null;
    await _database.mergeLocalIntoAccount(_accountScope);
    pendingOperationCount = await _database.outstandingOperationCount(_accountScope);
    attentionCount = await _database.attentionOperationCount(_accountScope);
    isOnline = true;
    isSignedIn = true;
    await _loadMe();
    notifyListeners();
    await flushQueue();
    await loadPlans();
  }

  /// Cached check of the public registration switch.
  Future<bool> fetchRegistrationStatus() async {
    if (_registrationEnabled != null) return _registrationEnabled!;
    try {
      final response = await _client.get(Uri.parse('$_baseUrl/v1/auth/registration-status'));
      _registrationEnabled = response.statusCode == 200 &&
          (jsonDecode(response.body) as Map<String, dynamic>)['enabled'] == true;
    } catch (_) {
      _registrationEnabled = false;
    }
    return _registrationEnabled!;
  }

  /// Loads owner status; a failed call degrades to a regular user view.
  Future<void> _loadMe() async {
    try {
      final response = await _authorized('GET', '/v1/auth/me');
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      isOwner = body['is_owner'] == true;
      email = body['email']?.toString();
    } catch (_) {
      isOwner = false;
    }
  }

  /// A 401 means the server has no valid identity for this device: the data
  /// belongs in the local workspace until a sign-in uploads it.
  bool _offlineable(ApiException error) => error.statusCode == 401;

  Future<void> signOut() async {
    // Remember which account owns the local data so it can be recovered
    // offline when the server is unreachable; a real sign-in clears it.
    if (_accountScope != LocalDatabase.localScope) {
      await _preferences.setString(_rememberedAccountScopeKey, _accountScope);
      _rememberedAccountScope = _accountScope;
    }
    await _secureStorage.delete(key: _accessTokenKey);
    await _secureStorage.delete(key: _refreshTokenKey);
    await _secureStorage.delete(key: _accountScopeKey);
    isSignedIn = false;
    isOwner = false;
    email = null;
    _accountScope = LocalDatabase.localScope;
    pendingOperationCount = await _database.outstandingOperationCount(_accountScope);
    attentionCount = await _database.attentionOperationCount(_accountScope);
    notifyListeners();
  }

  /// True when the previous account's local data can be restored without a
  /// network connection (server down, travel, accidental sign-out).
  bool get hasRecoverableData =>
      _rememberedAccountScope != null &&
      _rememberedAccountScope != LocalDatabase.localScope &&
      _rememberedAccountScope != _accountScope;

  /// Uses the remembered account's local data while signed out.  New records
  /// stay in that account's scope and upload once the user signs back in.
  Future<void> resumeLocalAccount() async {
    final scope = _rememberedAccountScope;
    if (scope == null || scope == LocalDatabase.localScope) return;
    _accountScope = scope;
    pendingOperationCount = await _database.outstandingOperationCount(_accountScope);
    attentionCount = await _database.attentionOperationCount(_accountScope);
    isOnline = false;
    lastSyncMessage = '已恢复本机数据（未登录）；联网后可登录继续同步';
    notifyListeners();
  }

  Future<({String email, String password})?> rememberedCredentials() async {
    final email = await _secureStorage.read(key: _rememberedEmailKey);
    final password = await _secureStorage.read(key: _rememberedPasswordKey);
    if (email == null || password == null || email.isEmpty || password.isEmpty) return null;
    return (email: email, password: password);
  }

  Future<void> rememberCredentials({required String email, required String password, required bool enabled}) async {
    if (!enabled) {
      await _secureStorage.delete(key: _rememberedEmailKey);
      await _secureStorage.delete(key: _rememberedPasswordKey);
      return;
    }
    await _secureStorage.write(key: _rememberedEmailKey, value: email.trim());
    await _secureStorage.write(key: _rememberedPasswordKey, value: password);
  }

  Future<List<Map<String, dynamic>>> cachedPlans() => _database.readPlans(_accountScope);

  /// Deletes one training plan; past workouts keep their snapshots.  Falls
  /// back to the sync journal when offline or signed out.
  Future<void> deletePlan(String planId) async {
    try {
      final response = await _authorized('DELETE', '/v1/plans/$planId');
      if (response.statusCode >= 400) {
        throw ApiException(response.statusCode, response.body);
      }
      await _database.deletePlan(_accountScope, planId);
      await _database.deletePlanDetail(_accountScope, planId);
      await loadPlans();
    } on ApiException catch (error) {
      if (!_offlineable(error)) rethrow;
      await _queuePlanDelete(planId);
    } catch (_) {
      await _queuePlanDelete(planId);
    }
  }

  Future<void> _queuePlanDelete(String planId) async {
    await _enqueueOperation(
      entityType: 'plan',
      entityId: planId,
      operationType: 'delete',
      payload: const <String, dynamic>{},
    );
    await _database.deletePlan(_accountScope, planId);
    await _database.deletePlanDetail(_accountScope, planId);
    isOnline = false;
    lastSyncMessage = isSignedIn ? '计划已离线删除，联网后同步' : '计划已在本机删除，登录后同步';
    await loadPlans();
  }

  Future<List<Map<String, dynamic>>> loadPlans() async {
    try {
      final response = await _authorized('GET', '/v1/plans');
      final plans = (jsonDecode(response.body) as List<dynamic>)
          .cast<Map<String, dynamic>>();
      await _database.cachePlans(_accountScope, plans);
      isOnline = true;
      lastSyncMessage = '计划已同步';
      notifyListeners();
      return plans;
    } catch (_) {
      isOnline = false;
      lastSyncMessage = '离线：显示本地缓存';
      notifyListeners();
      return _database.readPlans(_accountScope);
    }
  }

  Future<Map<String, dynamic>?> cachedPlanDetail(String planId) =>
      _database.readPlanDetail(_accountScope, planId);

  Future<Map<String, dynamic>?> loadPlanDetail(String planId) async {
    try {
      final response = await _authorized('GET', '/v1/plans/$planId');
      final detail = jsonDecode(response.body) as Map<String, dynamic>;
      await _database.cachePlanDetail(_accountScope, planId, detail);
      isOnline = true;
      notifyListeners();
      return detail;
    } catch (_) {
      isOnline = false;
      notifyListeners();
      return _database.readPlanDetail(_accountScope, planId);
    }
  }

  Future<List<Map<String, dynamic>>> loadExercises({
    String? search,
    String? purpose,
    List<String> tags = const [],
  }) async {
    final params = <String>[];
    if (search != null && search.trim().isNotEmpty) {
      params.add('search=${Uri.encodeQueryComponent(search.trim())}');
    }
    if (purpose != null && purpose.isNotEmpty) {
      params.add('purpose=$purpose');
    }
    for (final tag in tags) {
      if (tag.isNotEmpty) params.add('tag=${Uri.encodeQueryComponent(tag)}');
    }
    final query = params.isEmpty ? '' : '?${params.join('&')}';
    try {
      // Public content: no token required, cached in the shared local scope so
      // it stays visible after signing out or switching accounts.
      final response = await _client.get(Uri.parse('$_baseUrl/v1/library/exercises$query'));
      if (response.statusCode != 200) {
        throw ApiException(response.statusCode, response.body);
      }
      final exercises = (jsonDecode(response.body) as List<dynamic>)
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
      await _database.cacheExercises(LocalDatabase.localScope, exercises, cacheKind: 'published');
      isOnline = true;
      notifyListeners();
      return exercises;
    } catch (_) {
      isOnline = false;
      notifyListeners();
      return _database.readExercises(LocalDatabase.localScope, cacheKind: 'published', search: search);
    }
  }

  Future<Map<String, dynamic>> createExerciseDraft(
    Map<String, dynamic> draft,
  ) async {
    final response = await _authorized('POST', '/v1/library/exercises', body: draft);
    final created = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    final id = created['id']?.toString();
    if (id != null) await _database.cacheExercise(_accountScope, id, created, cacheKind: 'draft_summary');
    return created;
  }

  Future<List<Map<String, dynamic>>> loadExerciseDrafts() async {
    if (!isOwner) return const [];
    try {
      final response = await _authorized('GET', '/v1/library/drafts');
      final drafts = (jsonDecode(response.body) as List<dynamic>)
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
      await _database.removeExercisesWithPrefix(_accountScope, 'draft_summary');
      await _database.cacheExercises(_accountScope, drafts, cacheKind: 'draft_summary');
      isOnline = true;
      notifyListeners();
      return drafts;
    } catch (_) {
      isOnline = false;
      notifyListeners();
      return _database.readExercises(_accountScope, cacheKind: 'draft_summary');
    }
  }

  Future<Map<String, dynamic>> loadExerciseDraft({
    required String exerciseId,
    required int versionNo,
  }) async {
    final cacheKind = 'draft:$versionNo';
    try {
      final response = await _authorized(
        'GET',
        '/v1/library/drafts/$exerciseId/versions/$versionNo',
      );
      final draft = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
      await _database.cacheExercise(_accountScope, exerciseId, draft, cacheKind: cacheKind);
      isOnline = true;
      notifyListeners();
      return draft;
    } on ApiException catch (error) {
      if (error.statusCode == 404) {
        await _database.removeExercisesWithPrefix(_accountScope, 'draft_summary');
        await _database.removeExercisesWithPrefix(_accountScope, 'draft:$versionNo');
        rethrow;
      }
      final cached = await _database.readExercise(_accountScope, exerciseId, cacheKind: cacheKind);
      if (cached == null) rethrow;
      isOnline = false;
      notifyListeners();
      return cached;
    }
  }

  Future<void> updateExerciseDraft({
    required String exerciseId,
    required int versionNo,
    required Map<String, dynamic> draft,
  }) async {
    await _authorized(
      'PUT',
      '/v1/library/exercises/$exerciseId/versions/$versionNo',
      body: draft,
    );
    await _database.cacheExercise(
      _accountScope,
      exerciseId,
      draft,
      cacheKind: 'draft:$versionNo',
    );
  }

  Future<Map<String, dynamic>> createExerciseRevisionDraft(String exerciseId) async {
    final response = await _authorized('POST', '/v1/library/exercises/$exerciseId/versions/draft');
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<void> deleteExerciseMedia(String mediaId) async {
    await _authorized('DELETE', '/v1/library/media/$mediaId');
  }

  Future<void> deleteExerciseDraft({required String exerciseId, required int versionNo}) async {
    try {
      await _authorized('DELETE', '/v1/library/drafts/$exerciseId/versions/$versionNo');
    } on ApiException catch (error) {
      // A local stale draft is already gone on the server; deleting it from
      // this device is still the correct result.
      if (error.statusCode != 404) rethrow;
    }
    await _database.removeExercisesWithPrefix(_accountScope, 'draft_summary');
    await _database.removeExercisesWithPrefix(_accountScope, 'draft:$versionNo');
  }

  Future<Map<String, dynamic>> loadExerciseDetail(String exerciseId) async {
    try {
      // Public content, shared local cache: visible for every account state.
      final response = await _client.get(Uri.parse('$_baseUrl/v1/library/exercises/$exerciseId'));
      if (response.statusCode != 200) {
        throw ApiException(response.statusCode, response.body);
      }
      final detail = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
      await _database.cacheExercise(LocalDatabase.localScope, exerciseId, detail, cacheKind: 'published');
      isOnline = true;
      notifyListeners();
      return detail;
    } catch (_) {
      final cached = await _database.readExercise(LocalDatabase.localScope, exerciseId, cacheKind: 'published');
      if (cached == null) rethrow;
      isOnline = false;
      notifyListeners();
      return cached;
    }
  }

  Future<Map<String, dynamic>> uploadExerciseMedia({
    required String exerciseId,
    required int versionNo,
    required String filePath,
    required String altText,
    String mediaType = 'video',
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw const ApiException(422, '找不到所选的媒体文件。');
    }
    final token = await _secureStorage.read(key: _accessTokenKey);
    if (token == null) throw const ApiException(401, 'Not signed in');
    final extension = filePath.split('.').last.toLowerCase();
    final inferredMediaType = {'jpg', 'jpeg', 'png', 'webp'}.contains(extension)
        ? 'image'
        : mediaType;
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$_baseUrl/v1/library/exercises/$exerciseId/versions/$versionNo/media'),
    )
      ..headers['Authorization'] = 'Bearer $token'
      ..fields['alt_text_zh'] = altText
      ..fields['media_type'] = inferredMediaType
      ..files.add(await http.MultipartFile.fromPath('file', filePath));
    final response = await http.Response.fromStream(await request.send());
    if (response.statusCode >= 400) {
      throw ApiException(response.statusCode, response.body);
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<void> publishExercise({
    required String exerciseId,
    required int versionNo,
  }) async {
    await _authorized(
      'POST',
      '/v1/library/exercises/$exerciseId/versions/$versionNo/publish',
    );
    // Do not let a completed draft remain visible from the local cache.
    await _database.removeExercisesWithPrefix(_accountScope, 'draft_summary');
    await _database.removeExercisesWithPrefix(_accountScope, 'draft:$versionNo');
  }

  Future<void> createPlan(Map<String, dynamic> plan) async {
    try {
      final createdResponse = await _authorized('POST', '/v1/plans', body: plan);
      final created = Map<String, dynamic>.from(
        jsonDecode(createdResponse.body) as Map,
      );
      // The service creates an editable first version. The canvas already
      // validates that it has actionable content, so publish it as the usable
      // one-session training plan immediately.
      await _authorized(
        'POST',
        '/v1/plans/${created['id']}/versions/${created['current_version_no']}/publish',
        body: {'base_revision': created['revision']},
      );
      await loadPlans();
    } on ApiException catch (error) {
      if (!_offlineable(error)) rethrow;
      await _queuePlanCreate(plan);
    } catch (_) {
      await _queuePlanCreate(plan);
    }
  }

  Future<void> _queuePlanCreate(Map<String, dynamic> plan) async {
    await _enqueueOperation(
      entityType: 'plan',
      entityId: _newUuid(),
      operationType: 'create',
      payload: {
        'name': plan['name'],
        'goal': plan['goal'] ?? const <String, dynamic>{},
        'blocks': plan['blocks'] ?? const <dynamic>[],
      },
    );
    isOnline = false;
    lastSyncMessage = isSignedIn ? '计划已离线保存，联网后自动同步' : '计划已保存在本机，登录后自动同步';
    await loadPlans();
  }

  Future<void> replacePublishedPlan({
    required String planId,
    required List<Map<String, dynamic>> blocks,
  }) async {
    try {
      final draftResponse = await _authorized('POST', '/v1/plans/$planId/versions');
      final draft = Map<String, dynamic>.from(jsonDecode(draftResponse.body) as Map);
      final versionNo = draft['version_no'] as int;
      final replaced = await _authorized(
        'PUT',
        '/v1/plans/$planId/versions/$versionNo',
        body: {'base_revision': draft['revision'], 'blocks': blocks},
      );
      final replacement = Map<String, dynamic>.from(jsonDecode(replaced.body) as Map);
      await _authorized(
        'POST',
        '/v1/plans/$planId/versions/$versionNo/publish',
        body: {'base_revision': replacement['revision']},
      );
      await loadPlans();
    } on ApiException catch (error) {
      if (!_offlineable(error)) rethrow;
      await _queuePlanUpdate(planId, blocks);
    } catch (_) {
      await _queuePlanUpdate(planId, blocks);
    }
  }

  Future<void> _queuePlanUpdate(String planId, List<Map<String, dynamic>> blocks) async {
    // Offline: one journal operation replaces the published plan.  The server
    // rejects it with a conflict if another device changed the plan meanwhile,
    // which then surfaces as a needs_attention operation.
    final cached = await _database.readPlans(_accountScope);
    final plan = cached.where((item) => item['id'] == planId).firstOrNull;
    final baseRevision = (plan?['revision'] as num?)?.toInt() ?? 1;
    await _enqueueOperation(
      entityType: 'plan',
      entityId: planId,
      operationType: 'update',
      baseRevision: baseRevision,
      payload: {'blocks': blocks},
    );
    isOnline = false;
    lastSyncMessage = isSignedIn ? '计划修改已离线保存，联网后同步' : '计划修改已保存在本机，登录后同步';
    await loadPlans();
  }

  Future<Map<String, dynamic>> startWorkout(String planId) async {
    try {
      final response = await _authorized(
        'POST',
        '/v1/workouts/from-plan/$planId',
        body: {'timezone': 'Asia/Shanghai'},
      );
      final workout = jsonDecode(response.body) as Map<String, dynamic>;
      await _cacheOfflineWorkout(workout);
      isOnline = true;
      notifyListeners();
      return workout;
    } on ApiException catch (error) {
      if (!_offlineable(error)) rethrow;
      return _startOfflineWorkout(planId);
    } catch (_) {
      return _startOfflineWorkout(planId);
    }
  }

  /// Starts a workout without a valid identity or network: the session is
  /// built from cached plan/exercise data and created through the sync journal
  /// when the device signs in or reconnects.
  Future<Map<String, dynamic>> _startOfflineWorkout(String planId) async {
    final workout = await _buildOfflineWorkout(planId);
    await _enqueueOperation(
      entityType: 'workout_session',
      entityId: workout['id'] as String,
      operationType: 'create',
      payload: {
        'plan_id': planId,
        'timezone': 'Asia/Shanghai',
        'started_at': DateTime.now().toUtc().toIso8601String(),
      },
    );
    await _cacheOfflineWorkout(workout);
    isOnline = false;
    lastSyncMessage = isSignedIn ? '训练已离线开始，联网后自动同步' : '训练已在本机开始，登录后自动同步';
    notifyListeners();
    return workout;
  }

  /// Builds a locally complete workout view from the cached plan detail and
  /// published exercise cache, so the session page works with no network.
  Future<Map<String, dynamic>> _buildOfflineWorkout(String planId) async {
    final plan = await _database.readPlanDetail(_accountScope, planId) ?? const <String, dynamic>{};
    final exercises = await _database.readExercises(_accountScope, cacheKind: 'published');
    final items = <Map<String, dynamic>>[];
    var order = 1;
    for (final block in _maps(plan['blocks'])) {
      for (final slot in _maps(block['slots'])) {
        final exerciseId = slot['exercise_id']?.toString();
        final exercise = exerciseId == null
            ? null
            : exercises.where((item) => item['id'] == exerciseId).firstOrNull;
        items.add({
          'id': _newUuid(),
          'source_slot_id': null,
          'exercise_id': exerciseId,
          'exercise_version_no': slot['exercise_version_no'],
          'exercise_snapshot': {
            'name_zh': exercise?['name_zh'] ?? exerciseId ?? '训练动作',
            'name_en': exercise?['name_en'],
            'summary': exercise?['summary'],
            'recording_mode': exercise?['recording_mode'],
          },
          'prescription_snapshot': slot['prescription'] ?? const <String, dynamic>{},
          'alternatives': _maps(slot['alternatives']),
          'sort_order': order++,
          'set_logs': const <Map<String, dynamic>>[],
        });
      }
    }
    return {
      'id': _newUuid(),
      'source_plan_id': planId,
      'source_plan_version_no': (plan['current_version_no'] as num?)?.toInt(),
      'status': 'in_progress',
      'started_at': DateTime.now().toUtc().toIso8601String(),
      'ended_at': null,
      'timezone': 'Asia/Shanghai',
      'plan_name': plan['name'],
      'items': items,
    };
  }

  Future<Map<String, dynamic>?> loadActiveWorkout() async {
    try {
      final response = await _authorized('GET', '/v1/workouts/active');
      final body = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
      final workout = body['workout'];
      if (workout is Map) {
        final active = Map<String, dynamic>.from(workout);
        await _cacheOfflineWorkout(active);
        isOnline = true;
        notifyListeners();
        return active;
      }
      // No active workout on the server: drop any stale local copy.
      await _clearOfflineWorkout();
      return null;
    } catch (_) {
      // Offline: fall back to the last known resumable workout.
      return _readOfflineWorkout();
    }
  }

  Future<void> abandonWorkout(String sessionId) async {
    try {
      final response = await _authorized('POST', '/v1/workouts/$sessionId/abandon');
      if (response.statusCode != 200) throw ApiException(response.statusCode, response.body);
      await _clearOfflineWorkout();
      isOnline = true;
      notifyListeners();
    } on ApiException catch (error) {
      if (!_offlineable(error)) rethrow;
      await _queueWorkoutFinish(sessionId, 'abandoned');
    } catch (_) {
      await _queueWorkoutFinish(sessionId, 'abandoned');
    }
  }

  Future<void> _queueWorkoutFinish(String sessionId, String status) async {
    await _enqueueOperation(
      entityType: 'workout_session',
      entityId: sessionId,
      operationType: 'update',
      payload: {
        'status': status,
        'ended_at': DateTime.now().toUtc().toIso8601String(),
      },
    );
    await _clearOfflineWorkout();
    isOnline = false;
    lastSyncMessage = isSignedIn ? '训练已离线${status == 'abandoned' ? '放弃' : '完成'}，联网后同步' : '训练已在本机${status == 'abandoned' ? '放弃' : '完成'}，登录后同步';
    notifyListeners();
  }

  Future<List<Map<String, dynamic>>> loadWorkoutHistory({int limit = 50}) async {
    try {
      final response = await _authorized('GET', '/v1/workouts/history?limit=$limit');
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final entries = (body['entries'] as List<dynamic>)
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
      await _database.cacheWorkoutHistory(_accountScope, entries);
      isOnline = true;
      notifyListeners();
      return entries;
    } catch (_) {
      isOnline = false;
      notifyListeners();
      return _database.readWorkoutHistory(_accountScope, limit: limit);
    }
  }

  /// Loads the immutable plan/action snapshot used for a past workout.
  /// The endpoint is also available for in-progress workouts; callers decide
  /// which states they want to present.
  Future<Map<String, dynamic>> loadWorkoutDetail(String workoutSessionId) async {
    final response = await _authorized('GET', '/v1/workouts/$workoutSessionId');
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  /// Public taxonomy terms, used to build library filter dropdowns.
  Future<List<Map<String, dynamic>>> loadTaxonomy() async {
    try {
      final response = await _client.get(Uri.parse('$_baseUrl/v1/library/taxonomy'));
      if (response.statusCode != 200) {
        throw ApiException(response.statusCode, response.body);
      }
      return (jsonDecode(response.body) as List<dynamic>)
          .cast<Map<String, dynamic>>();
    } catch (_) {
      return const [];
    }
  }

  /// Marks one owned published exercise as no longer recommended in new plans.
  Future<void> deprecateExercise(String exerciseId) async {
    final response = await _authorized(
      'POST',
      '/v1/library/exercises/$exerciseId/deprecate',
    );
    if (response.statusCode >= 400) {
      throw ApiException(response.statusCode, response.body);
    }
    await _database.removeExercise(_accountScope, exerciseId, cacheKind: 'published');
  }

  /// Records accept/ignore on one progression suggestion.
  Future<void> decideSuggestion(String suggestionId, String decision) async {
    await _authorized(
      'PATCH',
      '/v1/progression/suggestions/$suggestionId',
      body: {'decision': decision},
    );
  }

  /// Downloads one media object into the local media cache and returns its
  /// file path, or null when offline and not yet cached.  Cache keys are
  /// derived from the object key, so re-downloads are idempotent.
  Future<String?> ensureMediaCached(String objectKey) async {
    if (objectKey.isEmpty) return null;
    try {
      final root = Directory(path.join(
        (await getApplicationSupportDirectory()).path,
        'training_book',
        'media',
      ));
      await root.create(recursive: true);
      final extension = objectKey.contains('.')
          ? '.${objectKey.split('.').last.toLowerCase()}'
          : '';
      final file = File(path.join(
        root.path,
        '${base64Url.encode(utf8.encode(objectKey)).replaceAll('=', '')}$extension',
      ));
      if (await file.exists()) return file.path;
      final response = await _client.get(Uri.parse('$_baseUrl/media/$objectKey'));
      if (response.statusCode != 200) return null;
      await file.writeAsBytes(response.bodyBytes, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  Future<void> _enqueueOperation({
    required String entityType,
    required String entityId,
    required String operationType,
    int? baseRevision,
    required Map<String, dynamic> payload,
  }) async {
    await _database.enqueueOperation(_accountScope, {
      'operation_id': _newUuid(),
      'entity_type': entityType,
      'entity_id': entityId,
      'operation_type': operationType,
      'base_revision': baseRevision,
      'payload': payload,
    });
    pendingOperationCount = await _database.outstandingOperationCount(_accountScope);
    notifyListeners();
  }

  Future<void> _cacheOfflineWorkout(Map<String, dynamic> workout) async {
    await _preferences.setString(_offlineWorkoutKey, jsonEncode(workout));
  }

  Future<Map<String, dynamic>?> _readOfflineWorkout() async {
    final raw = _preferences.getString(_offlineWorkoutKey);
    if (raw == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }

  Future<void> _clearOfflineWorkout() async {
    await _preferences.remove(_offlineWorkoutKey);
  }

  List<Map<String, dynamic>> _maps(Object? value) => value is List
      ? value.whereType<Map>().map((item) => item.cast<String, dynamic>()).toList()
      : const [];

  Future<Map<String, dynamic>> generateProgressionSuggestion(String workoutItemId) async {
    final response = await _authorized(
      'POST',
      '/v1/progression/suggestions',
      body: {'workout_item_id': workoutItemId},
    );
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<void> saveSet({
    required String sessionId,
    required String itemId,
    required int setNumber,
    required double? loadKg,
    required int? reps,
    required double? rpe,
  }) async {
    final body = <String, dynamic>{
      'set_type': 'working',
      'status': 'completed',
      'load_kg': loadKg,
      'reps': reps,
      'rpe': rpe,
      'technique_ok': true,
    };
    try {
      await _authorized(
        'PUT',
        '/v1/workouts/$sessionId/items/$itemId/sets/$setNumber',
        body: body,
      );
      await _updateOfflineSetLog(sessionId, itemId, setNumber, body);
      isOnline = true;
      notifyListeners();
    } on ApiException catch (error) {
      if (!_offlineable(error)) rethrow;
      await _enqueueSetLog(
        sessionId: sessionId,
        itemId: itemId,
        setNumber: setNumber,
        body: body,
      );
      await _updateOfflineSetLog(sessionId, itemId, setNumber, body);
      isOnline = false;
      lastSyncMessage = isSignedIn ? '已离线保存 1 组，等待同步' : '已在本机保存 1 组，登录后同步';
      notifyListeners();
    } catch (_) {
      await _enqueueSetLog(
        sessionId: sessionId,
        itemId: itemId,
        setNumber: setNumber,
        body: body,
      );
      await _updateOfflineSetLog(sessionId, itemId, setNumber, body);
      isOnline = false;
      lastSyncMessage = '已离线保存 1 组，等待同步';
      notifyListeners();
    }
  }

  /// Keeps the resumable offline workout copy in sync with recorded sets, so
  /// a restart in the gym still shows completed groups.
  Future<void> _updateOfflineSetLog(
    String sessionId,
    String itemId,
    int setNumber,
    Map<String, dynamic> log,
  ) async {
    final workout = await _readOfflineWorkout();
    if (workout == null || workout['id'] != sessionId) return;
    final items = _maps(workout['items']);
    for (final item in items) {
      if (item['id'] != itemId) continue;
      final logs = _maps(item['set_logs']);
      logs.removeWhere((entry) => (entry['set_number'] as num?)?.toInt() == setNumber);
      logs.add({...log, 'set_number': setNumber, 'id': itemId, 'status': 'completed'});
      item['set_logs'] = logs;
    }
    await _cacheOfflineWorkout({...workout, 'items': items});
  }

  Future<void> completeWorkout(String sessionId) async {
    try {
      await flushQueue();
      final response = await _authorized(
        'POST',
        '/v1/workouts/$sessionId/complete',
      );
      if (response.statusCode != 200) {
        throw ApiException(response.statusCode, response.body);
      }
      await _clearOfflineWorkout();
      isOnline = true;
      notifyListeners();
    } on ApiException catch (error) {
      if (!_offlineable(error)) rethrow;
      await _queueWorkoutFinish(sessionId, 'completed');
    } catch (_) {
      await _queueWorkoutFinish(sessionId, 'completed');
    }
  }

  /// Pushes durable local operations in server-sized batches, then advances the
  /// durable pull cursor. A conflicting or rejected operation stays in SQLite
  /// as `needs_attention`; it is never silently removed or retried blindly.
  Future<void> flushQueue() async {
    if (isSyncing) return;
    final queue = await _database.pendingOperations(_accountScope);
    if (queue.isEmpty) {
      await _pullRemoteChanges();
      pendingOperationCount = await _database.outstandingOperationCount(_accountScope);
      notifyListeners();
      return;
    }

    isSyncing = true;
    notifyListeners();
    try {
      final hasPlanOperation = queue.any((operation) => operation['entity_type'] == 'plan');
      for (var index = 0; index < queue.length; index += 100) {
        final batch = queue.sublist(index, min(index + 100, queue.length));
        final response = await _authorized(
          'POST',
          '/v1/sync/push',
          body: {'device_id': deviceId, 'operations': batch},
        );
        final body = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
        final returned = <String>{};
        for (final rawResult in body['results'] as List<dynamic>) {
          final result = Map<String, dynamic>.from(rawResult as Map);
          final operationId = result['operation_id']?.toString();
          if (operationId == null) continue;
          returned.add(operationId);
          final outcome = result['result']?.toString();
          if (outcome == 'accepted') {
            // A crash before this delete is safe: push uses operation_id as its
            // idempotency key and the server will return the journaled result.
            await _database.deleteOperation(_accountScope, operationId);
          } else {
            await _database.markOperationNeedsAttention(
              _accountScope,
              operationId,
              jsonEncode(result['detail'] ?? {'result': outcome ?? 'unknown'}),
            );
          }
        }
        final missingResults = batch
            .map((operation) => operation['operation_id'].toString())
            .where((operationId) => !returned.contains(operationId))
            .toList();
        await _database.markOperationAttempt(
          _accountScope,
          missingResults,
          'Server did not return an operation result',
        );
        final cursor = (body['next_cursor'] as num?)?.toInt();
        if (cursor != null) {
          await _database.setMetadata(_accountScope, 'sync_cursor', cursor.toString());
        }
      }
      await _pullRemoteChanges();
      if (hasPlanOperation) await loadPlans();
      final outstanding = await _database.outstandingOperationCount(_accountScope);
      final needsAttention = await _database.attentionOperationCount(_accountScope);
      attentionCount = needsAttention;
      pendingOperationCount = outstanding;
      isOnline = true;
      lastSyncMessage = needsAttention > 0
          ? '$needsAttention 条离线记录需要人工处理'
          : outstanding == 0
          ? '离线记录已同步'
          : '$outstanding 条记录仍在等待同步';
    } catch (error) {
      await _database.markOperationAttempt(
        _accountScope,
        queue.map((operation) => operation['operation_id'].toString()).toList(),
        _safeError(error),
      );
      isOnline = false;
      lastSyncMessage = '同步暂不可用，记录仍安全保存在本机';
    } finally {
      isSyncing = false;
      pendingOperationCount = await _database.outstandingOperationCount(_accountScope);
      attentionCount = await _database.attentionOperationCount(_accountScope);
      notifyListeners();
    }
  }

  /// Operations the server rejected or conflicted, waiting for a decision.
  Future<List<Map<String, dynamic>>> attentionOperations() =>
      _database.attentionOperations(_accountScope);

  /// Re-queues one attention operation and attempts a sync immediately.
  Future<void> retryAttentionOperation(String operationId) async {
    await _database.resetOperation(_accountScope, operationId);
    pendingOperationCount = await _database.outstandingOperationCount(_accountScope);
    notifyListeners();
    await flushQueue();
  }

  /// Removes one attention operation forever (the data behind it is lost).
  Future<void> discardAttentionOperation(String operationId) async {
    await _database.deleteOperation(_accountScope, operationId);
    pendingOperationCount = await _database.outstandingOperationCount(_accountScope);
    attentionCount = await _database.attentionOperationCount(_accountScope);
    notifyListeners();
  }

  Future<void> _pullRemoteChanges() async {
    var cursor = int.tryParse(await _database.getMetadata(_accountScope, 'sync_cursor') ?? '0') ?? 0;
    var hasMore = true;
    while (hasMore) {
      final response = await _authorized('GET', '/v1/sync/pull?cursor=$cursor&limit=200');
      final body = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
      final nextCursor = (body['next_cursor'] as num?)?.toInt() ?? cursor;
      await _database.setMetadata(_accountScope, 'sync_cursor', nextCursor.toString());
      // Pull is intentionally cursor-first: the journal currently contains
      // set-log mutations but not enough workout snapshots to reconstruct a
      // remote history entry safely. Existing REST reads refresh those views.
      // Persisting the cursor prevents endlessly re-reading remote operations.
      hasMore = body['has_more'] == true && nextCursor > cursor;
      cursor = nextCursor;
    }
  }

  /// Retained only for source-compatible diagnostics while old installations
  /// migrate.  All app code enters through the SQLite-backed [flushQueue].
  // ignore: unused_element
  Future<void> _legacyFlushQueue() async {
    final queue = _readQueue();
    if (queue.isEmpty || isSyncing) {
      return;
    }
    isSyncing = true;
    notifyListeners();
    try {
      final response = await _authorized(
        'POST',
        '/v1/sync/push',
        body: {'device_id': deviceId, 'operations': queue},
      );
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final results = (json['results'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final removable = <String>{
        for (final result in results)
          if (result['result'] == 'accepted' || result['result'] == 'rejected')
            result['operation_id'] as String,
      };
      final remaining = queue
          .where((operation) => !removable.contains(operation['operation_id']))
          .toList();
      await _writeQueue(remaining);
      await _preferences.setInt(_syncCursorKey, json['next_cursor'] as int);
      isOnline = true;
      lastSyncMessage = remaining.isEmpty
          ? '离线记录已同步'
          : '有 ${remaining.length} 条记录需要人工处理';
    } catch (_) {
      isOnline = false;
      lastSyncMessage = '同步暂不可用，记录仍安全保存在本机';
    } finally {
      isSyncing = false;
      pendingOperationCount = _readQueue().length;
      notifyListeners();
    }
  }

  Future<void> _enqueueSetLog({
    required String sessionId,
    required String itemId,
    required int setNumber,
    required Map<String, dynamic> body,
  }) async {
    await _database.enqueueOperation(_accountScope, {
      'operation_id': _newUuid(),
      'entity_type': 'set_log',
      'entity_id': _newUuid(),
      'operation_type': 'create',
      'base_revision': null,
      'payload': {
        'workout_session_id': sessionId,
        'workout_item_id': itemId,
        'set_number': setNumber,
        ...body,
      },
    });
    pendingOperationCount = await _database.outstandingOperationCount(_accountScope);
  }

  Future<http.Response> _authorized(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    var token = await _secureStorage.read(key: _accessTokenKey);
    if (token == null) {
      throw const ApiException(401, 'Not signed in');
    }
    var response = await _request(method, path, token, body);
    if (response.statusCode == 401 && await _refresh()) {
      token = await _secureStorage.read(key: _accessTokenKey);
      response = await _request(method, path, token!, body);
    }
    if (response.statusCode >= 400) {
      throw ApiException(response.statusCode, response.body);
    }
    return response;
  }

  Future<http.Response> _request(
    String method,
    String path,
    String token,
    Map<String, dynamic>? body,
  ) async {
    final request = http.Request(method, Uri.parse('$_baseUrl$path'))
      ..headers.addAll({
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      });
    if (body != null) {
      request.body = jsonEncode(body);
    }
    return http.Response.fromStream(await _client.send(request));
  }

  Future<bool> _refresh() {
    final inFlight = _refreshInFlight;
    if (inFlight != null) return inFlight;
    final refresh = _refreshOnce();
    _refreshInFlight = refresh;
    return refresh.whenComplete(() => _refreshInFlight = null);
  }

  Future<bool> _refreshOnce() async {
    final refreshToken = await _secureStorage.read(key: _refreshTokenKey);
    if (refreshToken == null) {
      return false;
    }
    try {
      final response = await _client.post(
        Uri.parse('$_baseUrl/v1/auth/refresh'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'refresh_token': refreshToken, 'device_id': deviceId}),
      );
      if (response.statusCode == 200) {
        await _storeSession(jsonDecode(response.body) as Map<String, dynamic>);
        return true;
      }
      // Only an explicit invalid/revoked credential ends the local session.
      // A temporary backend/network error must never throw the user back to login.
      if (response.statusCode == 401) await signOut();
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _storeSession(Map<String, dynamic> session) async {
    await _secureStorage.write(
      key: _accessTokenKey,
      value: session['access_token'] as String,
    );
    await _secureStorage.write(
      key: _refreshTokenKey,
      value: session['refresh_token'] as String,
    );
  }

  List<Map<String, dynamic>> _readQueue() => _readJsonList(_queueKey);

  List<Map<String, dynamic>> _readJsonList(String key) {
    final raw = _preferences.getString(key);
    if (raw == null) return [];
    return (jsonDecode(raw) as List<dynamic>)
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
  }

  Future<void> _writeQueue(List<Map<String, dynamic>> queue) async {
    await _preferences.setString(_queueKey, jsonEncode(queue));
    pendingOperationCount = queue.length;
  }

  String _accountScopeForEmail(String email) => email.trim().toLowerCase();

  String _safeError(Object error) {
    final text = error.toString().replaceAll(RegExp(r'[\r\n]+'), ' ');
    return text.length > 500 ? text.substring(0, 500) : text;
  }

  String _newUuid() {
    final random = Random.secure();
    final values = List<int>.generate(16, (_) => random.nextInt(256));
    values[6] = (values[6] & 0x0f) | 0x40;
    values[8] = (values[8] & 0x3f) | 0x80;
    final hex = values
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}

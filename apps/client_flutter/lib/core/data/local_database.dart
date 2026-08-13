import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The durable client-side store.
///
/// Server responses are intentionally kept as JSON documents here.  That lets
/// the API evolve without losing an offline cache, while the table boundaries
/// still make invalidation, migration and per-account data isolation explicit.
class LocalDatabase {
  LocalDatabase._(this._database);

  static const _schemaVersion = 1;
  static const legacyScope = '__legacy__';
  /// The signed-out workspace.  Everything created while not signed in lives
  /// here and is merged into an account when it signs in.
  static const localScope = '__local__';

  final Database _database;

  static Future<LocalDatabase> open(SharedPreferences preferences) async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final supportDirectory = await getApplicationSupportDirectory();
    final dataDirectory = Directory(path.join(supportDirectory.path, 'training_book'));
    if (!await dataDirectory.exists()) {
      await dataDirectory.create(recursive: true);
    }
    final database = await openDatabase(
      path.join(dataDirectory.path, 'training_book.sqlite'),
      version: _schemaVersion,
      onCreate: _create,
      onUpgrade: _upgrade,
    );
    final local = LocalDatabase._(database);
    await local._migrateSharedPreferences(preferences);
    return local;
  }

  static Future<void> _create(Database db, int version) async {
    await db.execute('''
      CREATE TABLE plans (
        account_scope TEXT NOT NULL,
        id TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        cached_at INTEGER NOT NULL,
        PRIMARY KEY (account_scope, id)
      )
    ''');
    await db.execute('''
      CREATE TABLE plan_details (
        account_scope TEXT NOT NULL,
        plan_id TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        cached_at INTEGER NOT NULL,
        PRIMARY KEY (account_scope, plan_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE exercises (
        account_scope TEXT NOT NULL,
        id TEXT NOT NULL,
        cache_kind TEXT NOT NULL,
        name_zh TEXT NOT NULL DEFAULT '',
        payload_json TEXT NOT NULL,
        cached_at INTEGER NOT NULL,
        PRIMARY KEY (account_scope, id, cache_kind)
      )
    ''');
    await db.execute('''
      CREATE TABLE workout_history (
        account_scope TEXT NOT NULL,
        id TEXT NOT NULL,
        started_at TEXT,
        payload_json TEXT NOT NULL,
        cached_at INTEGER NOT NULL,
        PRIMARY KEY (account_scope, id)
      )
    ''');
    await db.execute('''
      CREATE TABLE pending_operations (
        account_scope TEXT NOT NULL,
        operation_id TEXT NOT NULL,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        operation_type TEXT NOT NULL,
        base_revision INTEGER,
        payload_json TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'pending',
        attempts INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (account_scope, operation_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE sync_metadata (
        account_scope TEXT NOT NULL,
        metadata_key TEXT NOT NULL,
        metadata_value TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (account_scope, metadata_key)
      )
    ''');
    await db.execute('CREATE INDEX exercises_list_idx ON exercises(account_scope, cache_kind, name_zh)');
    await db.execute('CREATE INDEX workout_history_sort_idx ON workout_history(account_scope, started_at DESC)');
    await db.execute('CREATE INDEX pending_operations_state_idx ON pending_operations(account_scope, state, created_at)');
  }

  static Future<void> _upgrade(Database db, int oldVersion, int newVersion) async {
    // Keep migrations explicit.  Version 1 is the initial durable schema.
    if (oldVersion < 1) await _create(db, newVersion);
  }

  Future<void> _migrateSharedPreferences(SharedPreferences preferences) async {
    const migrationKey = 'shared_preferences_v1_imported';
    if (await getMetadata(legacyScope, migrationKey) == 'true') return;

    await _database.transaction((transaction) async {
      final plans = _decodeList(preferences.getString('plans_cache_v1'));
      for (final plan in plans) {
        final id = plan['id']?.toString();
        if (id != null) await _upsertPlan(transaction, legacyScope, id, plan);
      }

      for (final key in preferences.getKeys()) {
        if (!key.startsWith('plan_detail_v1_')) continue;
        final detail = _decodeObject(preferences.getString(key));
        final planId = detail?['id']?.toString() ?? key.substring('plan_detail_v1_'.length);
        if (detail != null && planId.isNotEmpty) {
          await _upsertPlanDetail(transaction, legacyScope, planId, detail);
        }
      }

      final history = _decodeList(preferences.getString('workout_history_cache_v1'));
      for (final entry in history) {
        final id = entry['id']?.toString();
        if (id != null) await _upsertWorkoutHistory(transaction, legacyScope, id, entry);
      }

      final queue = _decodeList(preferences.getString('sync_queue_v1'));
      for (final operation in queue) {
        final id = operation['operation_id']?.toString();
        if (id != null) await _insertOperation(transaction, legacyScope, operation);
      }

      final cursor = preferences.getInt('sync_cursor_v1');
      if (cursor != null) {
        await _setMetadata(transaction, legacyScope, 'sync_cursor', cursor.toString());
      }
      await _setMetadata(transaction, legacyScope, migrationKey, 'true');
    });
  }

  /// Moves the pre-SQLite cache into the first account that signs in, only when
  /// that account has no data.  This preserves older installs without leaking
  /// cached records into a different account.
  Future<void> adoptLegacyScopeIfEmpty(String accountScope) async {
    if (accountScope == legacyScope) return;
    final targetRows = Sqflite.firstIntValue(await _database.rawQuery(
      'SELECT (SELECT COUNT(*) FROM plans WHERE account_scope = ?) + '
      '(SELECT COUNT(*) FROM exercises WHERE account_scope = ?) + '
      '(SELECT COUNT(*) FROM workout_history WHERE account_scope = ?) AS total',
      [accountScope, accountScope, accountScope],
    )) ?? 0;
    if (targetRows > 0) return;
    final legacyRows = Sqflite.firstIntValue(await _database.rawQuery(
      'SELECT (SELECT COUNT(*) FROM plans WHERE account_scope = ?) + '
      '(SELECT COUNT(*) FROM exercises WHERE account_scope = ?) + '
      '(SELECT COUNT(*) FROM workout_history WHERE account_scope = ?) + '
      '(SELECT COUNT(*) FROM pending_operations WHERE account_scope = ?) AS total',
      [legacyScope, legacyScope, legacyScope, legacyScope],
    )) ?? 0;
    if (legacyRows == 0) return;

    await _database.transaction((transaction) async {
      for (final table in const [
        'plans',
        'plan_details',
        'exercises',
        'workout_history',
        'pending_operations',
        'sync_metadata',
      ]) {
        await transaction.update(table, {'account_scope': accountScope}, where: 'account_scope = ?', whereArgs: [legacyScope]);
      }
    });
  }

  /// Merges the signed-out local workspace (and any pre-SQLite leftovers) into
  /// an account the moment it signs in.  Rows the account already has win, so
  /// nothing from the account is ever overwritten by local-only data.
  Future<void> mergeLocalIntoAccount(String accountScope) async {
    if (accountScope == localScope) return;
    await _database.transaction((transaction) async {
      for (final source in const [localScope, legacyScope]) {
        await _mergeTable(transaction, 'plans', 'id', source, accountScope);
        await _mergeTable(transaction, 'plan_details', 'plan_id', source, accountScope);
        // exercises stay in the shared local scope: the library is public
        // content, not account data.
        await _mergeTable(transaction, 'workout_history', 'id', source, accountScope);
        await _mergeTable(transaction, 'pending_operations', 'operation_id', source, accountScope);
        await _mergeTable(transaction, 'sync_metadata', 'metadata_key', source, accountScope);
      }
    });
  }

  Future<void> _mergeTable(
    DatabaseExecutor transaction,
    String table,
    String idColumn,
    String source,
    String target,
  ) async {
    // The account keeps its own rows; local rows with the same key are dropped.
    await transaction.rawDelete(
      'DELETE FROM $table WHERE account_scope = ? AND $idColumn IN '
      '(SELECT $idColumn FROM $table WHERE account_scope = ?)',
      [source, target],
    );
    await transaction.update(
      table,
      {'account_scope': target},
      where: 'account_scope = ?',
      whereArgs: [source],
    );
  }

  Future<void> deletePlan(String accountScope, String planId) => _database.delete(
        'plans',
        where: 'account_scope = ? AND id = ?',
        whereArgs: [accountScope, planId],
      );

  Future<void> deletePlanDetail(String accountScope, String planId) => _database.delete(
        'plan_details',
        where: 'account_scope = ? AND plan_id = ?',
        whereArgs: [accountScope, planId],
      );

  Future<List<Map<String, dynamic>>> readPlans(String accountScope) =>
      _readDocuments('plans', accountScope, orderBy: 'cached_at DESC');

  Future<void> cachePlans(String accountScope, List<Map<String, dynamic>> plans) async {
    await _database.transaction((transaction) async {
      for (final plan in plans) {
        final id = plan['id']?.toString();
        if (id != null) await _upsertPlan(transaction, accountScope, id, plan);
      }
    });
  }

  Future<Map<String, dynamic>?> readPlanDetail(String accountScope, String planId) =>
      _readDocument('plan_details', accountScope, 'plan_id', planId);

  Future<void> cachePlanDetail(String accountScope, String planId, Map<String, dynamic> detail) =>
      _upsertPlanDetail(_database, accountScope, planId, detail);

  Future<List<Map<String, dynamic>>> readExercises(
    String accountScope, {
    required String cacheKind,
    String? search,
  }) async {
    final rows = await _database.query(
      'exercises',
      columns: const ['payload_json'],
      where: 'account_scope = ? AND cache_kind = ?',
      whereArgs: [accountScope, cacheKind],
      orderBy: 'name_zh COLLATE NOCASE ASC',
    );
    final normalizedSearch = search?.trim().toLowerCase();
    return rows
        .map((row) => _decodeRequired(row['payload_json'] as String))
        .where((exercise) {
          if (normalizedSearch == null || normalizedSearch.isEmpty) return true;
          return '${exercise['name_zh'] ?? ''} ${exercise['name_en'] ?? ''}'
              .toLowerCase()
              .contains(normalizedSearch);
        })
        .toList();
  }

  Future<Map<String, dynamic>?> readExercise(
    String accountScope,
    String exerciseId, {
    required String cacheKind,
  }) => _readDocument('exercises', accountScope, 'id', exerciseId, cacheKind: cacheKind);

  Future<void> cacheExercises(
    String accountScope,
    List<Map<String, dynamic>> exercises, {
    required String cacheKind,
  }) async {
    await _database.transaction((transaction) async {
      for (final exercise in exercises) {
        final id = exercise['id']?.toString();
        if (id != null) await _upsertExercise(transaction, accountScope, id, exercise, cacheKind);
      }
    });
  }

  Future<void> cacheExercise(
    String accountScope,
    String exerciseId,
    Map<String, dynamic> exercise, {
    required String cacheKind,
  }) => _upsertExercise(_database, accountScope, exerciseId, exercise, cacheKind);

  Future<void> removeExercisesWithPrefix(String accountScope, String prefix) => _database.delete(
        'exercises',
        where: 'account_scope = ? AND cache_kind LIKE ?',
        whereArgs: [accountScope, '$prefix%'],
      );

  Future<void> removeExercise(
    String accountScope,
    String exerciseId, {
    required String cacheKind,
  }) => _database.delete(
        'exercises',
        where: 'account_scope = ? AND id = ? AND cache_kind = ?',
        whereArgs: [accountScope, exerciseId, cacheKind],
      );

  Future<List<Map<String, dynamic>>> readWorkoutHistory(String accountScope, {required int limit}) async {
    final rows = await _database.query(
      'workout_history',
      columns: const ['payload_json'],
      where: 'account_scope = ?',
      whereArgs: [accountScope],
      orderBy: 'started_at DESC',
      limit: limit,
    );
    return rows.map((row) => _decodeRequired(row['payload_json'] as String)).toList();
  }

  Future<void> cacheWorkoutHistory(String accountScope, List<Map<String, dynamic>> entries) async {
    await _database.transaction((transaction) async {
      for (final entry in entries) {
        final id = entry['id']?.toString();
        if (id != null) await _upsertWorkoutHistory(transaction, accountScope, id, entry);
      }
    });
  }

  Future<List<Map<String, dynamic>>> pendingOperations(String accountScope) async {
    final rows = await _database.query(
      'pending_operations',
      where: 'account_scope = ? AND state = ?',
      whereArgs: [accountScope, 'pending'],
      orderBy: 'created_at ASC',
    );
    return rows.map(_operationFromRow).toList();
  }

  /// Operations the server rejected or conflicted; each needs a human decision.
  Future<List<Map<String, dynamic>>> attentionOperations(String accountScope) async {
    final rows = await _database.query(
      'pending_operations',
      where: 'account_scope = ? AND state = ?',
      whereArgs: [accountScope, 'needs_attention'],
      orderBy: 'updated_at DESC',
    );
    return rows.map((row) => {
      'operation_id': row['operation_id'],
      'entity_type': row['entity_type'],
      'entity_id': row['entity_id'],
      'operation_type': row['operation_type'],
      'base_revision': row['base_revision'],
      'last_error': row['last_error'],
      'updated_at': row['updated_at'],
      'payload': _decodeRequired(row['payload_json'] as String),
    }).toList();
  }

  Future<int> outstandingOperationCount(String accountScope) async {
    final rows = await _database.rawQuery(
      "SELECT COUNT(*) FROM pending_operations WHERE account_scope = ? AND state IN ('pending', 'needs_attention')",
      [accountScope],
    );
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  Future<int> attentionOperationCount(String accountScope) async {
    final rows = await _database.rawQuery(
      "SELECT COUNT(*) FROM pending_operations WHERE account_scope = ? AND state = 'needs_attention'",
      [accountScope],
    );
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  Future<void> enqueueOperation(String accountScope, Map<String, dynamic> operation) =>
      _insertOperation(_database, accountScope, operation);

  Future<void> markOperationAttempt(String accountScope, List<String> operationIds, String error) async {
    if (operationIds.isEmpty) return;
    final placeholders = List.filled(operationIds.length, '?').join(', ');
    await _database.rawUpdate(
      'UPDATE pending_operations SET attempts = attempts + 1, last_error = ?, updated_at = ? '
      'WHERE account_scope = ? AND state = ? AND operation_id IN ($placeholders)',
      [error, _now(), accountScope, 'pending', ...operationIds],
    );
  }

  Future<void> markOperationNeedsAttention(String accountScope, String operationId, String detail) => _database.update(
        'pending_operations',
        {'state': 'needs_attention', 'last_error': detail, 'updated_at': _now()},
        where: 'account_scope = ? AND operation_id = ?',
        whereArgs: [accountScope, operationId],
      );

  Future<void> resetOperation(String accountScope, String operationId) => _database.update(
        'pending_operations',
        {'state': 'pending', 'last_error': null, 'updated_at': _now()},
        where: 'account_scope = ? AND operation_id = ?',
        whereArgs: [accountScope, operationId],
      );

  Future<void> deleteOperation(String accountScope, String operationId) => _database.delete(
        'pending_operations',
        where: 'account_scope = ? AND operation_id = ?',
        whereArgs: [accountScope, operationId],
      );

  Future<String?> getMetadata(String accountScope, String key) async {
    final rows = await _database.query(
      'sync_metadata',
      columns: const ['metadata_value'],
      where: 'account_scope = ? AND metadata_key = ?',
      whereArgs: [accountScope, key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['metadata_value'] as String;
  }

  Future<void> setMetadata(String accountScope, String key, String value) =>
      _setMetadata(_database, accountScope, key, value);

  Future<void> _upsertPlan(DatabaseExecutor executor, String accountScope, String id, Map<String, dynamic> plan) =>
      executor.insert('plans', {
        'account_scope': accountScope,
        'id': id,
        'payload_json': jsonEncode(plan),
        'cached_at': _now(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> _upsertPlanDetail(DatabaseExecutor executor, String accountScope, String planId, Map<String, dynamic> detail) =>
      executor.insert('plan_details', {
        'account_scope': accountScope,
        'plan_id': planId,
        'payload_json': jsonEncode(detail),
        'cached_at': _now(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> _upsertExercise(
    DatabaseExecutor executor,
    String accountScope,
    String id,
    Map<String, dynamic> exercise,
    String cacheKind,
  ) => executor.insert('exercises', {
        'account_scope': accountScope,
        'id': id,
        'cache_kind': cacheKind,
        'name_zh': exercise['name_zh']?.toString() ?? '',
        'payload_json': jsonEncode(exercise),
        'cached_at': _now(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> _upsertWorkoutHistory(DatabaseExecutor executor, String accountScope, String id, Map<String, dynamic> entry) =>
      executor.insert('workout_history', {
        'account_scope': accountScope,
        'id': id,
        'started_at': entry['started_at']?.toString(),
        'payload_json': jsonEncode(entry),
        'cached_at': _now(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> _insertOperation(DatabaseExecutor executor, String accountScope, Map<String, dynamic> operation) =>
      executor.insert('pending_operations', {
        'account_scope': accountScope,
        'operation_id': operation['operation_id']?.toString(),
        'entity_type': operation['entity_type']?.toString() ?? '',
        'entity_id': operation['entity_id']?.toString() ?? '',
        'operation_type': operation['operation_type']?.toString() ?? '',
        'base_revision': operation['base_revision'],
        'payload_json': jsonEncode(operation['payload'] ?? const <String, dynamic>{}),
        'state': 'pending',
        'attempts': 0,
        'created_at': _now(),
        'updated_at': _now(),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);

  Future<void> _setMetadata(DatabaseExecutor executor, String accountScope, String key, String value) =>
      executor.insert('sync_metadata', {
        'account_scope': accountScope,
        'metadata_key': key,
        'metadata_value': value,
        'updated_at': _now(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<List<Map<String, dynamic>>> _readDocuments(String table, String accountScope, {String? orderBy}) async {
    final rows = await _database.query(
      table,
      columns: const ['payload_json'],
      where: 'account_scope = ?',
      whereArgs: [accountScope],
      orderBy: orderBy,
    );
    return rows.map((row) => _decodeRequired(row['payload_json'] as String)).toList();
  }

  Future<Map<String, dynamic>?> _readDocument(
    String table,
    String accountScope,
    String idColumn,
    String id, {
    String? cacheKind,
  }) async {
    final where = cacheKind == null
        ? 'account_scope = ? AND $idColumn = ?'
        : 'account_scope = ? AND $idColumn = ? AND cache_kind = ?';
    final values = cacheKind == null ? [accountScope, id] : [accountScope, id, cacheKind];
    final rows = await _database.query(
      table,
      columns: const ['payload_json'],
      where: where,
      whereArgs: values,
      limit: 1,
    );
    return rows.isEmpty ? null : _decodeRequired(rows.first['payload_json'] as String);
  }

  Map<String, dynamic> _operationFromRow(Map<String, Object?> row) => {
        'operation_id': row['operation_id'],
        'entity_type': row['entity_type'],
        'entity_id': row['entity_id'],
        'operation_type': row['operation_type'],
        'base_revision': row['base_revision'],
        'payload': _decodeRequired(row['payload_json'] as String),
      };

  List<Map<String, dynamic>> _decodeList(String? raw) {
    if (raw == null) return const [];
    try {
      final value = jsonDecode(raw);
      if (value is! List) return const [];
      return value.whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList();
    } on FormatException {
      return const [];
    }
  }

  Map<String, dynamic>? _decodeObject(String? raw) {
    if (raw == null) return null;
    try {
      final value = jsonDecode(raw);
      return value is Map ? Map<String, dynamic>.from(value) : null;
    } on FormatException {
      return null;
    }
  }

  Map<String, dynamic> _decodeRequired(String raw) => _decodeObject(raw) ?? const {};

  static int _now() => DateTime.now().millisecondsSinceEpoch;
}

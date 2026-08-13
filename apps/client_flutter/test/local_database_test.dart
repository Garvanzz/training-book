import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:training_book/core/data/local_database.dart';

/// Exercises the offline queue rules behind the sync engine: the store must
/// never hand the server two create operations for the same set, or the
/// server's `set_number_already_recorded` conflict turns one offline re-save
/// into a fake needs-attention entry.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LocalDatabase database;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    tempDir = Directory.systemTemp.createTempSync('training_book_test');
    database = await LocalDatabase.open(preferences, overrideDirectory: tempDir);
  });

  tearDown(() async {
    try {
      await database.close();
    } catch (_) {
      // A test that already closed or replaced the store must not fail here.
    }
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Map<String, dynamic> setLogOperation({
    required String operationId,
    required String itemId,
    required int setNumber,
  }) => {
    'operation_id': operationId,
    'entity_type': 'set_log',
    'entity_id': operationId,
    'operation_type': 'create',
    'base_revision': null,
    'payload': {
      'workout_session_id': 'session-1',
      'workout_item_id': itemId,
      'set_number': setNumber,
      'status': 'completed',
    },
  };

  test('coalescePendingSetLog removes an earlier pending create for the same set', () async {
    await database.enqueueOperation(
      LocalDatabase.localScope,
      setLogOperation(operationId: 'op-1', itemId: 'item-1', setNumber: 2),
    );
    await database.enqueueOperation(
      LocalDatabase.localScope,
      setLogOperation(operationId: 'op-2', itemId: 'item-1', setNumber: 2),
    );

    await database.coalescePendingSetLog(LocalDatabase.localScope, 'item-1', 2);

    expect(await database.pendingOperations(LocalDatabase.localScope), isEmpty);
  });

  test('coalescePendingSetLog leaves other sets and items untouched', () async {
    await database.enqueueOperation(
      LocalDatabase.localScope,
      setLogOperation(operationId: 'op-1', itemId: 'item-1', setNumber: 1),
    );
    await database.enqueueOperation(
      LocalDatabase.localScope,
      setLogOperation(operationId: 'op-2', itemId: 'item-1', setNumber: 2),
    );
    await database.enqueueOperation(
      LocalDatabase.localScope,
      setLogOperation(operationId: 'op-3', itemId: 'item-2', setNumber: 2),
    );

    await database.coalescePendingSetLog(LocalDatabase.localScope, 'item-1', 2);

    final remaining = await database.pendingOperations(LocalDatabase.localScope);
    expect(remaining.map((operation) => operation['operation_id']), ['op-1', 'op-3']);
  });

  test('coalescePendingSetLog ignores non-set_log operations', () async {
    await database.enqueueOperation(LocalDatabase.localScope, {
      'operation_id': 'op-plan',
      'entity_type': 'plan',
      'entity_id': 'plan-1',
      'operation_type': 'delete',
      'base_revision': null,
      'payload': <String, dynamic>{},
    });

    await database.coalescePendingSetLog(LocalDatabase.localScope, 'item-1', 2);

    final remaining = await database.pendingOperations(LocalDatabase.localScope);
    expect(remaining.single['operation_id'], 'op-plan');
  });

  test('pending set logs survive a reopen of the store', () async {
    await database.enqueueOperation(
      LocalDatabase.localScope,
      setLogOperation(operationId: 'op-1', itemId: 'item-1', setNumber: 1),
    );
    await database.close();

    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    database = await LocalDatabase.open(preferences, overrideDirectory: tempDir);

    final pending = await database.pendingOperations(LocalDatabase.localScope);
    expect(pending.single['operation_id'], 'op-1');
  });

  test('mergeLocalIntoAccount migrates pending operations to the account scope', () async {
    await database.enqueueOperation(
      LocalDatabase.localScope,
      setLogOperation(operationId: 'op-1', itemId: 'item-1', setNumber: 1),
    );
    await database.enqueueOperation(
      LocalDatabase.localScope,
      setLogOperation(operationId: 'op-2', itemId: 'item-1', setNumber: 2),
    );

    await database.mergeLocalIntoAccount('user@example.com');

    expect(await database.pendingOperations(LocalDatabase.localScope), isEmpty);
    final accountPending = await database.pendingOperations('user@example.com');
    expect(accountPending.map((operation) => operation['operation_id']), ['op-1', 'op-2']);
  });
}

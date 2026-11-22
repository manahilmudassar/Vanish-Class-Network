import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import '../models/chat_message.dart';

/// Local SQLite database service for Vanish Class Network.
/// 
/// Manages the local SQLite database `vanish_messages.db` on this device.
/// Stores outgoing messages, incoming peer messages, delivery status updates,
/// and handles automatic pruning of expired messages according to synchronized server time.
class MessageDatabaseService {
  MessageDatabaseService._();
  static final MessageDatabaseService instance = MessageDatabaseService._();

  Database? _database;
  bool _isInitializing = false;
  final List<ChatMessage> _savedMessagesForTesting = [];
  final List<String> _deletedMessageIdsForTesting = [];

  @visibleForTesting
  set databaseForTesting(Database? db) {
    _database = db;
  }

  @visibleForTesting
  List<ChatMessage> get savedMessagesForTesting =>
      List.unmodifiable(_savedMessagesForTesting);

  @visibleForTesting
  List<String> get deletedMessageIdsForTesting =>
      List.unmodifiable(_deletedMessageIdsForTesting);

  @visibleForTesting
  void clearTestRecords() {
    _savedMessagesForTesting.clear();
    _deletedMessageIdsForTesting.clear();
  }

  /// Opens or retrieves the local SQLite database.
  Future<Database> get database async {
    if (_database != null && _database!.isOpen) return _database!;

    while (_isInitializing) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (_database != null && _database!.isOpen) return _database!;
    }

    _isInitializing = true;
    try {
      final dbPath = await getDatabasesPath();
      final fullPath = p.join(dbPath, 'vanish_messages.db');
      final dbFile = File(fullPath);
      final exists = dbFile.existsSync();
      final fileSize = exists ? dbFile.lengthSync() : 0;

      debugPrint('================================================================');
      debugPrint('[SQLITE DIAGNOSTIC] Opening SQLite database:');
      debugPrint('[SQLITE DIAGNOSTIC] getDatabasesPath(): "$dbPath"');
      debugPrint('[SQLITE DIAGNOSTIC] Full Database Path: "$fullPath"');
      debugPrint('[SQLITE DIAGNOSTIC] Database File Name: "${p.basename(fullPath)}"');
      debugPrint('[SQLITE DIAGNOSTIC] File exists on disk: $exists ($fileSize bytes)');
      debugPrint('[SQLITE DIAGNOSTIC] WAL file exists: ${File('$fullPath-wal').existsSync()}');
      debugPrint('================================================================');

      developer.log(
        'Initializing local SQLite database: $fullPath',
        name: 'MessageDatabaseService',
      );

      _database = await openDatabase(
        fullPath,
        version: 1,
        onCreate: (db, version) async {
          debugPrint('[SQLITE DIAGNOSTIC] onCreate triggered! Creating "messages" table in $fullPath');
          developer.log(
            'Creating SQLite "messages" table in vanish_messages.db',
            name: 'MessageDatabaseService',
          );
          await db.execute('''
            CREATE TABLE messages (
              id TEXT PRIMARY KEY,
              sender_id TEXT NOT NULL,
              sender_name TEXT NOT NULL,
              content TEXT NOT NULL,
              room TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              delivered_at INTEGER,
              expires_at INTEGER NOT NULL,
              status TEXT NOT NULL,
              delivery_count INTEGER
            )
          ''');
          debugPrint('[SQLITE DIAGNOSTIC] onCreate: "messages" table created successfully.');
          developer.log(
            'SQLite table "messages" created successfully',
            name: 'MessageDatabaseService',
          );
        },
        onOpen: (db) async {
          final version = await db.getVersion();
          final tables = await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table'");
          final tableNames = tables.map((t) => t['name']).toList();
          debugPrint('[SQLITE DIAGNOSTIC] onOpen: Database opened. Version: $version, Tables: $tableNames');
          if (tableNames.contains('messages')) {
            final colInfo = await db.rawQuery('PRAGMA table_info(messages)');
            final colList = colInfo.map((c) => '${c["name"]}(${c["type"]})').toList();
            final countRes = await db.rawQuery('SELECT COUNT(*) as count FROM messages');
            final count = Sqflite.firstIntValue(countRes) ?? 0;
            debugPrint('[SQLITE DIAGNOSTIC] onOpen: "messages" columns: $colList');
            debugPrint('[SQLITE DIAGNOSTIC] onOpen: Initial row count in "messages": $count');
          } else {
            debugPrint('[SQLITE DIAGNOSTIC] onOpen: WARNING! "messages" table is MISSING in $fullPath!');
          }
          developer.log(
            'SQLite database vanish_messages.db ready for inspection',
            name: 'MessageDatabaseService',
          );
        },
      );

      return _database!;
    } catch (e, stack) {
      debugPrint('[SQLITE DIAGNOSTIC] Failed to open SQLite database: $e');
      debugPrint('[SQLITE DIAGNOSTIC] Open error stack: $stack');
      developer.log(
        'Failed to open SQLite database: $e',
        name: 'MessageDatabaseService',
        error: e,
        stackTrace: stack,
      );
      rethrow;
    } finally {
      _isInitializing = false;
    }
  }

  /// Saves or updates a message in the local SQLite database.
  /// 
  /// Uses [ConflictAlgorithm.replace] so existing records (e.g. delivery status
  /// or delivery count updates) are modified in place without creating duplicates.
  Future<bool> saveMessage(ChatMessage message) async {
    _savedMessagesForTesting.add(message);
    debugPrint('[SQLITE DIAGNOSTIC] >>> ENTER saveMessage() for ID: "${message.id}"');
    debugPrint('[SQLITE DIAGNOSTIC] Message details: sender="${message.senderName}", content="${message.content}", status=${message.status.name}');
    try {
      final db = await database;
      debugPrint('[SQLITE DIAGNOSTIC] Database handle acquired: path="${db.path}", isOpen=${db.isOpen}');

      final dbMap = message.toDbMap();
      debugPrint('[SQLITE DIAGNOSTIC] Executing db.insert("messages", ...): $dbMap');

      final rowId = await db.insert(
        'messages',
        dbMap,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      debugPrint('[SQLITE DIAGNOSTIC] SQLite INSERT SUCCESS: returned rowId=$rowId for ID: "${message.id}"');

      // Check and log the exact total number of rows in the table
      final countResult = await db.rawQuery('SELECT COUNT(*) as count FROM messages');
      final totalRows = Sqflite.firstIntValue(countResult) ?? 0;
      final currentRows = await db.query(
        'messages',
        columns: ['id', 'sender_name', 'status', 'created_at', 'expires_at'],
      );
      debugPrint('[SQLITE DIAGNOSTIC] >>> TOTAL ROWS in "messages" table NOW: $totalRows');
      debugPrint('[SQLITE DIAGNOSTIC] >>> Current rows in table: $currentRows');

      developer.log(
        'SQLite INSERT/REPLACE success: id=${message.id}, status=${message.status.name}, expires_at=${message.expiresAt.millisecondsSinceEpoch}',
        name: 'MessageDatabaseService',
      );
      return true;
    } catch (e, stack) {
      debugPrint('[SQLITE DIAGNOSTIC] >>> SQLite INSERT FAILED for ID "${message.id}": $e');
      debugPrint('[SQLITE DIAGNOSTIC] >>> Failure stack: $stack');
      developer.log(
        'SQLite INSERT/UPDATE error for message ${message.id}: $e',
        name: 'MessageDatabaseService',
        error: e,
        stackTrace: stack,
      );
      return false;
    }
  }

  /// Deletes a specific message row by its unique ID.
  Future<bool> deleteMessage(String id) async {
    _deletedMessageIdsForTesting.add(id);
    _savedMessagesForTesting.removeWhere((m) => m.id == id);
    debugPrint('[SQLITE DIAGNOSTIC] deleteMessage() called for ID: "$id"');
    try {
      final db = await database;
      final count = await db.delete(
        'messages',
        where: 'id = ?',
        whereArgs: [id],
      );
      debugPrint('[SQLITE DIAGNOSTIC] deleteMessage() completed for ID: "$id" (rows deleted: $count)');
      developer.log(
        'SQLite DELETE message: id=$id (rows removed: $count)',
        name: 'MessageDatabaseService',
      );
      return count > 0;
    } catch (e, stack) {
      debugPrint('[SQLITE DIAGNOSTIC] deleteMessage() FAILED for ID: "$id": $e');
      developer.log(
        'SQLite DELETE error for message $id: $e',
        name: 'MessageDatabaseService',
        error: e,
        stackTrace: stack,
      );
      return false;
    }
  }

  /// Deletes all messages whose original expiry has elapsed (expires_at <= syncNow).
  /// 
  /// Conforms to deletion condition: expires_at <= synchronizedNow.
  Future<int> deleteExpiredMessages(DateTime syncNow) async {
    final thresholdMs = syncNow.millisecondsSinceEpoch;
    final expiredInTest = _savedMessagesForTesting
        .where((m) => m.expiresAt.millisecondsSinceEpoch <= thresholdMs)
        .map((m) => m.id)
        .toList();
    _deletedMessageIdsForTesting.addAll(expiredInTest);
    _savedMessagesForTesting.removeWhere(
        (m) => m.expiresAt.millisecondsSinceEpoch <= thresholdMs);
    debugPrint('[SQLITE DIAGNOSTIC] deleteExpiredMessages() called with threshold: $thresholdMs (${syncNow.toIso8601String()})');
    try {
      final db = await database;
      final count = await db.delete(
        'messages',
        where: 'expires_at <= ?',
        whereArgs: [thresholdMs],
      );
      if (count > 0) {
        debugPrint('[SQLITE DIAGNOSTIC] deleteExpiredMessages(): deleted $count expired row(s) from SQLite.');
        developer.log(
          'SQLite PRUNE EXPIRED: deleted $count message(s) where expires_at <= $thresholdMs',
          name: 'MessageDatabaseService',
        );
      }
      return count;
    } catch (e, stack) {
      debugPrint('[SQLITE DIAGNOSTIC] deleteExpiredMessages() FAILED: $e');
      developer.log(
        'SQLite PRUNE EXPIRED error at ${syncNow.toIso8601String()}: $e',
        name: 'MessageDatabaseService',
        error: e,
        stackTrace: stack,
      );
      return 0;
    }
  }

  /// Retrieves unexpired messages (expires_at > syncNow) sorted by creation time.
  Future<List<ChatMessage>> getActiveMessages(DateTime syncNow) async {
    try {
      final db = await database;
      final maps = await db.query(
        'messages',
        where: 'expires_at > ?',
        whereArgs: [syncNow.millisecondsSinceEpoch],
        orderBy: 'created_at ASC',
      );
      developer.log(
        'SQLite QUERY ACTIVE: found ${maps.length} active message(s)',
        name: 'MessageDatabaseService',
      );
      return maps.map((m) => ChatMessage.fromDbMap(m)).toList();
    } catch (e, stack) {
      developer.log(
        'SQLite QUERY ACTIVE error: $e',
        name: 'MessageDatabaseService',
        error: e,
        stackTrace: stack,
      );
      return [];
    }
  }

  /// Retrieves all messages in the table, primarily for inspection and verification.
  Future<List<ChatMessage>> getAllMessages() async {
    try {
      final db = await database;
      final maps = await db.query(
        'messages',
        orderBy: 'created_at ASC',
      );
      return maps.map((m) => ChatMessage.fromDbMap(m)).toList();
    } catch (e, stack) {
      developer.log(
        'SQLite QUERY ALL error: $e',
        name: 'MessageDatabaseService',
        error: e,
        stackTrace: stack,
      );
      return [];
    }
  }

  /// Retrieves a specific message by its unique ID.
  Future<ChatMessage?> getMessageById(String id) async {
    try {
      final db = await database;
      final maps = await db.query(
        'messages',
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (maps.isNotEmpty) {
        return ChatMessage.fromDbMap(maps.first);
      }
      return null;
    } catch (e, stack) {
      developer.log(
        'SQLite GET BY ID error for $id: $e',
        name: 'MessageDatabaseService',
        error: e,
        stackTrace: stack,
      );
      return null;
    }
  }

  /// Clears all message rows from the database.
  Future<void> clearAllMessages() async {
    _savedMessagesForTesting.clear();
    try {
      final db = await database;
      final count = await db.delete('messages');
      developer.log(
        'SQLite CLEAR ALL: removed $count messages',
        name: 'MessageDatabaseService',
      );
    } catch (e, stack) {
      developer.log(
        'SQLite CLEAR ALL error: $e',
        name: 'MessageDatabaseService',
        error: e,
        stackTrace: stack,
      );
    }
  }

  /// Closes the database connection.
  Future<void> close() async {
    if (_database != null && _database!.isOpen) {
      await _database!.close();
      _database = null;
    }
  }
}

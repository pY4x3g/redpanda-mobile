import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'database.g.dart';

// Tables
// ... (imports remain)

// Tables
class Users extends Table {
  TextColumn get uuid => text().unique()();
  TextColumn get username => text()();
  TextColumn get avatarUrl => text().nullable()();
  TextColumn get publicKey => text().nullable()();

  @override
  Set<Column> get primaryKey => {uuid};
}

class Channels extends Table {
  TextColumn get uuid => text().unique()();
  TextColumn get username => text()();
  TextColumn get privateKey => text().nullable()(); // Added privateKey
  DateTimeColumn get lastSeen => dateTime().nullable()();
  BoolColumn get isOnline => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {uuid};
}

class Messages extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get conversationId =>
      text().references(Channels, #uuid)(); // Updated reference
  TextColumn get senderId => text()();
  TextColumn get content => text()();
  DateTimeColumn get timestamp => dateTime()();
  IntColumn get status => integer()(); // Enum index
  IntColumn get type => integer()(); // Enum index
}

class Peers extends Table {
  TextColumn get address => text().unique()();
  TextColumn get nodeId => text().nullable()();
  IntColumn get averageLatencyMs =>
      integer().withDefault(const Constant(9999))();
  IntColumn get successCount => integer().withDefault(const Constant(0))();
  IntColumn get failureCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastSeen => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {address};
}

@DriftDatabase(tables: [Users, Channels, Messages, Peers])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 4; // Incremented schema version to 4 for nodeId

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        await m.createAll();
      },
      onUpgrade: (Migrator m, int from, int to) async {
        if (from < 2) {
          // Since we are renaming/changing significantly, for development simplifying by re-creating or adding new table.
          // For now, let's just create the new table and drop the old one if needed, or better:
          // Since we changed the class name, Drift sees it as a new table 'channels'.
          // 'Contacts' table will remain but be unused unless we drop it.
          await m.createTable(channels);
          // Note: In real app we might want to migrate data from contacts to channels.
        }
        if (from < 3) {
          await m.createTable(peers);
        }
        if (from < 4) {
          await m.addColumn(peers, peers.nodeId);
        }
      },
    );
  }

  static QueryExecutor _openConnection() {
    return driftDatabase(
      name: 'redpanda_db',
      native: const DriftNativeOptions(shareAcrossIsolates: true),
      web: DriftWebOptions(
        sqlite3Wasm: Uri.parse('sqlite3.wasm'),
        driftWorker: Uri.parse('drift_worker.js'),
      ),
    );
  }
}

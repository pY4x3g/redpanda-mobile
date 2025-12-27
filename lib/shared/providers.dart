import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:redpanda/database/database.dart';

final dbProvider = Provider<AppDatabase>((ref) {
  return AppDatabase();
});

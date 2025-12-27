import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:redpanda/router.dart';
import 'package:redpanda/shared/providers.dart';

void main() {
  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> {
  @override
  void initState() {
    super.initState();
    // Trigger connection startup once
    ref.read(redPandaClientProvider).connect();
  }

  @override
  Widget build(BuildContext context) {
    // Router provider might also need to be accessible. Check if it's in shared/providers or router.dart
    // Based on previous file, routerProvider was accessed via `ref.watch(routerProvider)`.
    // Assuming it is exported from router.dart or shared. 
    // Previous code: `import 'package:redpanda/router.dart';` and `final router = ref.watch(routerProvider);`
    final router = ref.watch(routerProvider);
    
    return MaterialApp.router(
      title: 'RedPanda Chat',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFE91E63)),
        useMaterial3: true,
      ),
      routerConfig: router,
    );
  }
}

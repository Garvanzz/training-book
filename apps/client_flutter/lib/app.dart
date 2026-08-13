import 'package:flutter/material.dart';

import 'core/data/training_repository.dart';
import 'core/theme/app_theme.dart';
import 'features/shell/presentation/app_shell.dart';

class TrainingBookApp extends StatefulWidget {
  const TrainingBookApp({super.key});

  @override
  State<TrainingBookApp> createState() => _TrainingBookAppState();
}

class _TrainingBookAppState extends State<TrainingBookApp> {
  TrainingRepository? _repository;

  @override
  void initState() {
    super.initState();
    TrainingRepository.create().then((repository) {
      if (mounted) setState(() => _repository = repository);
    });
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '训练簿',
    debugShowCheckedModeBanner: false,
    theme: AppTheme.dark(),
    home: _repository == null
        ? const Scaffold(body: Center(child: CircularProgressIndicator()))
        : AppShell(repository: _repository!),
  );
}

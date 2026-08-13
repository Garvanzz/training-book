import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:training_book/app.dart';

void main() {
  testWidgets('mounts the application while persisted session initializes', (tester) async {
    await tester.pumpWidget(const TrainingBookApp());

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}

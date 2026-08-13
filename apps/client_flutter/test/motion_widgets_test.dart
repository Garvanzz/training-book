import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_book/core/widgets/appear_in.dart';

void main() {
  FadeTransition fadeOf(WidgetTester tester) => tester.widget<FadeTransition>(
    find.descendant(of: find.byType(AppearIn), matching: find.byType(FadeTransition)).first,
  );

  testWidgets('AppearIn respects delay before starting its entrance', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AppearIn(delay: Duration(seconds: 1), child: Text('内容'))),
      ),
    );

    // Within the delay the animation must not have started.
    expect(fadeOf(tester).opacity.value, 0.0);
    await tester.pump(const Duration(milliseconds: 500));
    expect(fadeOf(tester).opacity.value, 0.0);

    // After the delay the entrance runs.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 16));
    expect(fadeOf(tester).opacity.value, greaterThan(0.0));
  });

  testWidgets('AppearIn with no delay starts immediately', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AppearIn(child: Text('内容')))),
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(fadeOf(tester).opacity.value, greaterThan(0.0));
  });
}

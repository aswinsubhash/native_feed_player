import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:native_feed_player_example/main.dart';

void main() {
  testWidgets('renders feed shell', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}

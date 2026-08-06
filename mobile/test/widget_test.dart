import 'package:flutter_test/flutter_test.dart';

import 'package:multiscan_mobile/main.dart';

void main() {
  testWidgets('renders the MultiScan splash screen', (WidgetTester tester) async {
    await tester.pumpWidget(const MultiScanApp());
    expect(find.text('MultiScan'), findsOneWidget);
  });
}

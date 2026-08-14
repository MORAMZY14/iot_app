import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iot/main.dart';

void main() {
  testWidgets('renders the Smart Home splash screen', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MyApp(),
      ),
    );

    expect(find.text('Smart Home'), findsOneWidget);
    expect(find.text('Starting services'), findsOneWidget);
  });
}

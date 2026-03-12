import 'package:flutter_test/flutter_test.dart';
import 'package:vm_launcher/app.dart';

void main() {
  testWidgets('App launches smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const VmLauncherApp());
    expect(find.text('Geogram Dev VM Setup'), findsOneWidget);
  });
}

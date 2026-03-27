import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geogram/models/chat_channel.dart';
import 'package:geogram/widgets/new_channel_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('creates decentralized group channels with icon metadata', (
    WidgetTester tester,
  ) async {
    ChatChannel? createdChannel;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  createdChannel = await Navigator.push<ChatChannel>(
                    context,
                    MaterialPageRoute(
                      builder: (context) =>
                          const NewChannelDialog(existingChannelIds: []),
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Decentralized'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(0), 'Mesh Camp');
    await tester.enterText(
      find.byType(TextFormField).at(1),
      'Distributed field coordination',
    );
    await tester.enterText(find.byType(TextFormField).at(2), '🛰️');

    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(createdChannel, isNotNull);
    expect(createdChannel!.name, 'Mesh Camp');
    expect(createdChannel!.folder, 'dchat/mesh-camp');
    expect(createdChannel!.config?.isDistributed, isTrue);
    expect(createdChannel!.config?.icon, '🛰️');
    expect(createdChannel!.config?.visibility, 'RESTRICTED');
    expect(createdChannel!.config?.fileUpload, isFalse);
  });
}

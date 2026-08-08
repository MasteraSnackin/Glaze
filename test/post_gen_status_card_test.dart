import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/chat/state/post_gen_status_provider.dart';
import 'package:glaze_flutter/features/chat/widgets/post_gen_status_card.dart';
import 'package:glaze_flutter/shared/widgets/glaze_spinner.dart';

void main() {
  testWidgets('shows a distinct Ledger reconciliation running badge', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(postGenStatusProvider.notifier)
        .state = const PostGenStatusState.running(
      sessionId: 'session-1',
      task: PostGenTask.ledgerReconciliation,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: PostGenStatusCard(sessionId: 'session-1')),
        ),
      ),
    );

    expect(find.text('Ledger reconciliation running...'), findsOneWidget);
    expect(find.byType(GlazeSpinner), findsOneWidget);
  });

  testWidgets('shows the Card evolution observation pass', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(postGenStatusProvider.notifier)
        .state = const PostGenStatusState.running(
      sessionId: 'session-1',
      task: PostGenTask.cardEvolutionObservation,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: PostGenStatusCard(sessionId: 'session-1')),
        ),
      ),
    );

    expect(find.text('Card evolution observations running...'), findsOneWidget);
    expect(find.byType(GlazeSpinner), findsOneWidget);
  });

  testWidgets('shows a distinct Card Rewriter running badge', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(postGenStatusProvider.notifier)
        .state = const PostGenStatusState.running(
      sessionId: 'session-1',
      task: PostGenTask.cardRewriter,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: PostGenStatusCard(sessionId: 'session-1')),
        ),
      ),
    );

    expect(find.text('Card Rewriter running...'), findsOneWidget);
    expect(find.byType(GlazeSpinner), findsOneWidget);
  });
}

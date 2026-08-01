import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../db/repositories/card_evolution_repo.dart';
import '../../llm/card_rewrite_slot_resolver.dart';
import '../../models/agent_operation_record.dart';
import '../../utils/id_generator.dart';
import '../../utils/time_helpers.dart';
import 'card_rewrite_operation_parser.dart';
import 'card_rewrite_prompt_builder.dart';
import 'card_rewriter_contracts.dart';
import 'manual_rewrite_service.dart';

/// Dedicated review-only automation lane. Claim and final commit are repository
/// operations; the only work between them is shared-context prompt assembly and
/// two bounded, cancellable writer calls.
class AutomatedCardEvolutionService {
  AutomatedCardEvolutionService({
    required this.repo,
    required this.resolveModel,
    required this._executor,
    this.isEnabled,
    this.leaseSeconds = 300,
  });

  final CardEvolutionRepo repo;
  final CardRewriteModelResolver resolveModel;
  final CardRewriteLlmExecutor _executor;
  final bool Function()? isEnabled;
  final int leaseSeconds;
  final Map<String, CancelToken> _tokens = {};
  final Map<String, Future<CardEvolutionFinalizeOutcome?>> _inFlight = {};

  Future<CardEvolutionFinalizeOutcome?> runOneBatch(String sessionId) {
    if (isEnabled?.call() == false) return Future.value(null);
    final active = _inFlight[sessionId];
    if (active != null) return active;
    final future = _run(sessionId);
    _inFlight[sessionId] = future;
    return future.whenComplete(() => _inFlight.remove(sessionId));
  }

  Future<CardEvolutionFinalizeOutcome?> _run(String sessionId) async {
    final owner = 'evolution-owner-${generateId()}';
    final now = currentTimestampSeconds();
    final claimed = await repo.claim(
      sessionId: sessionId,
      ownerId: owner,
      now: now,
      leaseSeconds: leaseSeconds,
    );
    final claim = claimed.claim;
    if (claim == null) return null;
    CancelToken? token;
    try {
      final snapshot = await repo.readPromptSnapshot(
        claimId: claim.row.id,
        ownerId: owner,
        now: currentTimestampSeconds(),
      );
      if (snapshot == null) return null;
      final config = await resolveModel();
      token = CancelToken();
      _tokens[sessionId] = token;
      final sharedContext = snapshot.selectedInputJson;
      final cardPrompt =
          '${CardRewriterPromptBuilder.buildEvolution(character: snapshot.character, instruction: 'Use all three card fields, the 20 latest immutable chat messages, and the current Ledger-backed factual context below to infer durable character evolution. Ledger supports the chat evidence; it does not replace it. Return patches only for fields with a durable, supported change. Change the smallest exact fragments possible; do not rewrite a whole field or card. Do not invent canon.')}\n\n# Immutable chat history and effective canon\n${snapshot.selectedInputJson}';
      final cardOutcome = await _executor(
        config: config,
        prompt: cardPrompt,
        maxTokens: 4096,
        temperature: 0.2,
        timeoutMs: 60000,
        cancelToken: token,
      );
      if (token.isCancelled ||
          cardOutcome.status == AgentOperationStatus.aborted ||
          !cardOutcome.isOk ||
          cardOutcome.text == null) {
        return null;
      }
      final cardOperations = CardRewriteOperationParser.parseEvolutionBatch(
        cardOutcome.text!,
      );
      if (cardOperations == null) return null;
      final operations = <RewriteOperationSnapshot>[...cardOperations];
      String? lorebookOutput;
      if (_hasInjectedLoreTargets(sharedContext)) {
        final lorebookOutcome = await _executor(
          config: config,
          prompt:
              '${CardRewriterPromptBuilder.buildLorebookEvolution(instruction: 'Use the shared card, chat, and Ledger context to keep only the supplied injected lorebook entries current. Return patches only when an entry needs a durable update.')}\n\n# Shared immutable context\n$sharedContext',
          maxTokens: 4096,
          temperature: 0.2,
          timeoutMs: 60000,
          cancelToken: token,
        );
        if (token.isCancelled ||
            lorebookOutcome.status == AgentOperationStatus.aborted ||
            !lorebookOutcome.isOk ||
            lorebookOutcome.text == null) {
          return null;
        }
        final lorebookOperations =
            CardRewriteOperationParser.parseLorebookEvolutionBatch(
              lorebookOutcome.text!,
            );
        if (lorebookOperations == null) return null;
        operations.addAll(lorebookOperations);
        lorebookOutput = lorebookOutcome.text;
      }
      if (operations.isEmpty) return null;
      final modelOutputs = <String, String>{'card': cardOutcome.text!};
      if (lorebookOutput != null) modelOutputs['lorebook'] = lorebookOutput;
      return repo.finalize(
        claimId: claim.row.id,
        ownerId: owner,
        now: currentTimestampSeconds(),
        modelOutput: jsonEncode(modelOutputs),
        operations: operations,
      );
    } on CardRewriteModelNotConfigured {
      return null;
    } catch (_) {
      return null;
    } finally {
      if (token != null && identical(_tokens[sessionId], token)) {
        _tokens.remove(sessionId);
      }
    }
  }

  void cancelSession(String sessionId) {
    _tokens[sessionId]?.cancel('generationAborted');
  }

  void dispose() {
    for (final token in _tokens.values) {
      token.cancel('serviceDisposed');
    }
    _tokens.clear();
  }

  static bool _hasInjectedLoreTargets(String selectedInputJson) {
    try {
      final input = jsonDecode(selectedInputJson) as Map;
      final entries = input['injectedLorebookEntries'];
      return entries is List && entries.isNotEmpty;
    } catch (_) {
      return false;
    }
  }
}

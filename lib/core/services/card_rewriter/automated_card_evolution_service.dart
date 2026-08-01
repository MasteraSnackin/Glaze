import 'dart:async';

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
/// operations; the only work between them is effective-card prompt assembly and
/// one cancellable model call.
class AutomatedCardEvolutionService {
  AutomatedCardEvolutionService({
    required this.repo,
    required this.resolveModel,
    required this._executor,
    this.leaseSeconds = 300,
  });

  final CardEvolutionRepo repo;
  final CardRewriteModelResolver resolveModel;
  final CardRewriteLlmExecutor _executor;
  final int leaseSeconds;
  final Map<String, CancelToken> _tokens = {};
  final Map<String, Future<CardEvolutionFinalizeOutcome?>> _inFlight = {};

  Future<CardEvolutionFinalizeOutcome?> runOneBatch(String sessionId) {
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
      final prompt = '${CardRewriterPromptBuilder.build(
        character: snapshot.character,
        field: CardRewriteField.description,
        instruction: 'Evolve the description only when the exact accepted evidence below supports a durable development. Consolidate rather than append. Do not invent unsupported canon.',
      )}\n\n# Exact accepted immutable evidence\n${snapshot.selectedInputJson}';
      final config = await resolveModel();
      token = CancelToken();
      _tokens[sessionId] = token;
      final outcome = await _executor(
        config: config,
        prompt: prompt,
        maxTokens: 4096,
        temperature: 0.2,
        timeoutMs: 60000,
        cancelToken: token,
      );
      if (token.isCancelled ||
          outcome.status == AgentOperationStatus.aborted ||
          !outcome.isOk ||
          outcome.text == null) {
        return null;
      }
      final parsed = CardRewriteOperationParser.parse(
        outcome.text!,
        expectedField: CardRewriteField.description,
      );
      if (parsed.snapshot == null) {
        return null;
      }
      return repo.finalize(
        claimId: claim.row.id,
        ownerId: owner,
        now: currentTimestampSeconds(),
        modelOutput: outcome.text!,
        operation: parsed.snapshot!,
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
}

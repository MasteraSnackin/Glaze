import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../db/repositories/card_evolution_repo.dart';
import '../../llm/card_rewrite_slot_resolver.dart';
import '../../llm/aux_retry_runner.dart';
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
    this.isLorebookEvolutionEnabled,
    this.timeoutMs = 180000,
    this.leaseSeconds = 300,
  });

  final CardEvolutionRepo repo;
  final CardRewriteModelResolver resolveModel;
  final CardRewriteLlmExecutor _executor;
  final bool Function()? isEnabled;
  final bool Function()? isLorebookEvolutionEnabled;
  final int timeoutMs;
  final int leaseSeconds;
  final Map<String, CancelToken> _tokens = {};
  final Map<String, Future<CardEvolutionFinalizeOutcome>> _inFlight = {};

  Future<CardEvolutionFinalizeOutcome> runOneBatch(String sessionId) {
    if (isEnabled?.call() == false) {
      return Future.value(const CardEvolutionFinalizeOutcome('disabled'));
    }
    final active = _inFlight[sessionId];
    if (active != null) return active;
    final future = _run(sessionId);
    _inFlight[sessionId] = future;
    return future.whenComplete(() => _inFlight.remove(sessionId));
  }

  Future<CardEvolutionFinalizeOutcome> _run(String sessionId) async {
    final owner = 'evolution-owner-${generateId()}';
    final now = currentTimestampSeconds();
    final claimed = await repo.claim(
      sessionId: sessionId,
      ownerId: owner,
      now: now,
      leaseSeconds: leaseSeconds,
    );
    final claim = claimed.claim;
    if (claim == null) return CardEvolutionFinalizeOutcome(claimed.kind);
    CancelToken? token;
    var finalized = false;
    try {
      final snapshot = await repo.readPromptSnapshot(
        claimId: claim.row.id,
        ownerId: owner,
        now: currentTimestampSeconds(),
      );
      if (snapshot == null) {
        return const CardEvolutionFinalizeOutcome('snapshotUnavailable');
      }
      final config = await resolveModel();
      token = CancelToken();
      _tokens[sessionId] = token;
      final sharedContext = snapshot.selectedInputJson;
      final allowedCardFields = CardRewritePolicy.nonEmptyEvolutionFields(
        snapshot.character,
      );
      final operations = <RewriteOperationSnapshot>[];
      final cardOperations = <CardRewriteOperationSnapshot>[];
      String? cardOutput;
      if (allowedCardFields.isNotEmpty) {
        final cardPrompt =
            '${CardRewriterPromptBuilder.buildEvolution(character: snapshot.character, instruction: 'Use the available non-empty card fields, the 20 latest immutable chat messages, and the current Ledger-backed factual context below to infer durable character evolution. Ledger supports the chat evidence; it does not replace it. Return patches only for fields with a durable, supported change. Change the smallest exact fragments possible; do not rewrite a whole field or card. Do not invent canon.')}\n\n# Immutable chat history and effective canon\n${snapshot.selectedInputJson}';
        final cardOutcome = await _executor(
          config: config,
          prompt: cardPrompt,
          maxTokens: 4096,
          temperature: 0.2,
          timeoutMs: timeoutMs,
          cancelToken: token,
        );
        await _saveDebugOutcome(
          sessionId: sessionId,
          stage: 'card',
          model: config.model,
          outcome: cardOutcome,
        );
        if (token.isCancelled ||
            cardOutcome.status == AgentOperationStatus.aborted ||
            !cardOutcome.isOk ||
            cardOutcome.text == null) {
          return CardEvolutionFinalizeOutcome(
            token.isCancelled || cardOutcome.status == AgentOperationStatus.aborted
                ? 'cancelled'
                : 'cardModelFailed',
            null,
            _modelFailureDetail(cardOutcome),
          );
        }
        final parsedCardOperations = CardRewriteOperationParser.parseEvolutionBatch(
          cardOutcome.text!,
          allowedFields: allowedCardFields,
        );
        if (parsedCardOperations == null) {
          return CardEvolutionFinalizeOutcome(
            'invalidCardOutput',
            null,
            _diagnostic(
              CardRewriteOperationParser.explainEvolutionBatchFailure(
                cardOutcome.text!,
                allowedFields: allowedCardFields,
              ),
              cardOutcome.text!,
            ),
          );
        }
        cardOperations.addAll(parsedCardOperations);
        operations.addAll(cardOperations);
        cardOutput = cardOutcome.text;
      }
      String? lorebookOutput;
      if (isLorebookEvolutionEnabled?.call() != false &&
          _hasInjectedLoreTargets(sharedContext)) {
        final lorebookOutcome = await _executor(
          config: config,
          prompt:
               '${CardRewriterPromptBuilder.buildLorebookEvolution(instruction: 'Use the shared card, chat, and Ledger context to keep only the supplied injected lorebook entries current. Prefer the card for character relationships and enduring behavior; prefer lorebook entries for their specific locations, people, objects, or setting facts. Do not duplicate a current or proposed card fact into lorebook. Return a patch whenever the chat supports a durable update that belongs in an injected entry and is not already covered by the card.')}\n\n# Shared immutable context\n$sharedContext\n\n# Proposed card operations (read-only)\n${_cardProposalContext(cardOperations)}',
          maxTokens: 4096,
          temperature: 0.2,
          timeoutMs: timeoutMs,
          cancelToken: token,
        );
        await _saveDebugOutcome(
          sessionId: sessionId,
          stage: 'lorebook',
          model: config.model,
          outcome: lorebookOutcome,
        );
        if (token.isCancelled ||
            lorebookOutcome.status == AgentOperationStatus.aborted ||
            !lorebookOutcome.isOk ||
            lorebookOutcome.text == null) {
          return CardEvolutionFinalizeOutcome(
            token.isCancelled ||
                    lorebookOutcome.status == AgentOperationStatus.aborted
                ? 'cancelled'
                : 'lorebookModelFailed',
            null,
            _modelFailureDetail(lorebookOutcome),
          );
        }
        final lorebookOperations =
            CardRewriteOperationParser.parseLorebookEvolutionBatch(
              lorebookOutcome.text!,
            );
        if (lorebookOperations == null) {
          return const CardEvolutionFinalizeOutcome('invalidLorebookOutput');
        }
        operations.addAll(lorebookOperations);
        lorebookOutput = lorebookOutcome.text;
      }
      if (operations.isEmpty) {
        return const CardEvolutionFinalizeOutcome(
          'emptyModelProposal',
          null,
          'Every enabled writer returned an empty operations list. Check the '
              'saved card/lorebook debug responses.',
        );
      }
      final modelOutputs = <String, String>{};
      if (cardOutput != null) modelOutputs['card'] = cardOutput;
      if (lorebookOutput != null) modelOutputs['lorebook'] = lorebookOutput;
      final result = await repo.finalize(
        claimId: claim.row.id,
        ownerId: owner,
        now: currentTimestampSeconds(),
        modelOutput: jsonEncode(modelOutputs),
        operations: operations,
      );
      finalized = result.isPersisted;
      return result;
    } on CardRewriteModelNotConfigured {
      return const CardEvolutionFinalizeOutcome('modelNotConfigured');
    } catch (_) {
      return const CardEvolutionFinalizeOutcome('unexpectedFailure');
    } finally {
      if (token != null && identical(_tokens[sessionId], token)) {
        _tokens.remove(sessionId);
      }
      if (!finalized) {
        await repo.abandonClaim(claimId: claim.row.id, ownerId: owner);
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

  static String _cardProposalContext(
    List<CardRewriteOperationSnapshot> operations,
  ) => jsonEncode([
    for (final operation in operations)
      jsonDecode(ManualRewriteOperationSnapshotCodec.encode(operation)),
  ]);

  static String _diagnostic(String? reason, String output) {
    final compact = output.replaceAll(RegExp(r'\s+'), ' ').trim();
    final preview = compact.length > 240 ? '${compact.substring(0, 240)}...' : compact;
    return '${reason ?? 'unrecognized response'}; response: $preview';
  }

  static String _modelFailureDetail(AuxCallOutcome outcome) {
    final attempts = outcome.attempts;
    if (attempts.isEmpty) return 'status: ${outcome.status.name}';
    final last = attempts.last;
    final error = last.error?.replaceAll(RegExp(r'\s+'), ' ').trim();
    final compactError = error == null || error.isEmpty
        ? ''
        : ': ${error.length > 180 ? '${error.substring(0, 180)}...' : error}';
    final code = last.statusCode == 0 ? '' : ' HTTP ${last.statusCode}';
    return '${attempts.length} attempt(s), ${last.status}$code$compactError';
  }

  Future<void> _saveDebugOutcome({
    required String sessionId,
    required String stage,
    required String model,
    required AuxCallOutcome outcome,
  }) => repo.saveDebugRun(
    sessionId: sessionId,
    stage: stage,
    status: outcome.status.name,
    model: model,
    output: outcome.text,
    attemptsJson: jsonEncode([
      for (final attempt in outcome.attempts) attempt.toJson(),
    ]),
    updatedAt: currentTimestampSeconds(),
  );
}

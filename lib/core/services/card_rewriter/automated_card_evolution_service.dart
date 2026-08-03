import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../db/repositories/card_evolution_observation_repo.dart';
import '../../db/repositories/card_evolution_repo.dart';
import '../../llm/card_rewrite_slot_resolver.dart';
import '../../llm/aux_retry_runner.dart';
import '../../models/agent_operation_record.dart';
import '../../models/card_evolution_observation.dart';
import '../../utils/id_generator.dart';
import '../../utils/time_helpers.dart';
import 'card_rewrite_operation_parser.dart';
import 'card_rewrite_prompt_builder.dart';
import 'card_rewriter_contracts.dart';
import 'manual_rewrite_service.dart';

const _writerMaxTokens = 20000;

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
    CardEvolutionObservationRepo? observationRepo,
    this.observationPromotionThreshold,
    this.observationMinConfidence,
    this.observationExpiryRuns,
  }) : observationRepo =
           observationRepo ?? CardEvolutionObservationRepo(repo.db);

  final CardEvolutionRepo repo;
  final CardEvolutionObservationRepo observationRepo;
  final CardRewriteModelResolver resolveModel;
  final CardRewriteLlmExecutor _executor;
  final bool Function()? isEnabled;
  final bool Function()? isLorebookEvolutionEnabled;
  final int timeoutMs;
  final int leaseSeconds;
  final int Function()? observationPromotionThreshold;
  final double Function()? observationMinConfidence;
  final int Function()? observationExpiryRuns;
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
    await _maybeRunObservationPass(sessionId);
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
        final validatedTargets = _extractValidatedTargets(
          snapshot.selectedInputJson,
        );
        final cardPrompt =
            '${CardRewriterPromptBuilder.buildEvolution(character: snapshot.character, instruction: 'Use the available non-empty card fields, the 40 latest immutable chat messages, and the current Ledger-backed factual context below to infer durable character evolution. Ledger supports the chat evidence; it does not replace it. Return patches only for fields with a durable, supported change. Change the smallest exact fragments possible; do not rewrite a whole field or card. Do not invent canon.', validatedTargets: validatedTargets)}\n\n# Immutable chat history and effective canon\n${snapshot.selectedInputJson}';
        final cardOutcome = await _executor(
          config: config,
          prompt: cardPrompt,
          maxTokens: _writerMaxTokens,
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
            token.isCancelled ||
                    cardOutcome.status == AgentOperationStatus.aborted
                ? 'cancelled'
                : 'cardModelFailed',
            null,
            _modelFailureDetail(cardOutcome),
          );
        }
        final parsedCardOperations =
            CardRewriteOperationParser.parseEvolutionBatch(
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
          maxTokens: _writerMaxTokens,
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
      if (finalized) {
        await repo.consumePromotedObservations(
          sessionId,
          now: currentTimestampSeconds(),
        );
      }
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
    _tokens['observation-$sessionId']?.cancel('generationAborted');
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

  /// Runs the observation pass when the cadence gate is active (every 2nd
  /// successful reconciliation). Failures are non-blocking: the card writer
  /// continues without validated targets.
  Future<void> _maybeRunObservationPass(String sessionId) async {
    try {
      final count = await repo.countSuccessfulReconciliations(sessionId);
      if (count == 0 || count % 2 != 0) return;
      final runOrdinal = count ~/ 2;
      await _runObservationPass(sessionId, runOrdinal);
      await _checkPromotionsAndExpiry(sessionId, runOrdinal);
    } catch (_) {
      // Observation pass failures are intentionally non-blocking.
    }
  }

  Future<void> _runObservationPass(String sessionId, int runOrdinal) async {
    final snapshot = await repo.buildObservationSnapshot(sessionId);
    if (snapshot == null) return;
    final config = await resolveModel();
    final active = await observationRepo.getActiveObservations(sessionId);
    final activeMaps = active
        .map(
          (o) => <String, Object?>{
            'scopeKey': o.semanticScopeKey,
            'observedChange': o.observedChange,
            'canonicalClaim': o.canonicalClaim,
            'repeatCount': o.repeatCount,
            'firstSeenRun': o.firstSeenRun,
            'lastConfirmedRun': o.lastConfirmedRun,
            'confidence': o.confidence,
          },
        )
        .toList();
    final prompt =
        '${CardRewriterPromptBuilder.buildObservationPass(character: snapshot.character, activeObservations: activeMaps, instruction: 'Review the last 40 immutable chat messages and the current Ledger-backed canon below. For each active observation, decide whether the chat history still supports it. Identify any new repeatedly demonstrated shift in preference, attitude, relationship dynamics, or lasting character development. Do not record one-off events or temporary state. Be conservative.')}\n\n# Immutable chat history and effective canon\n${snapshot.selectedInputJson}';
    final token = CancelToken();
    _tokens['observation-$sessionId'] = token;
    try {
      if (token.isCancelled) return;
      final outcome = await _executor(
        config: config,
        prompt: prompt,
        maxTokens: _writerMaxTokens,
        temperature: 0.2,
        timeoutMs: timeoutMs,
        cancelToken: token,
      );
      if (token.isCancelled ||
          outcome.status == AgentOperationStatus.aborted ||
          !outcome.isOk ||
          outcome.text == null) {
        return;
      }
      final actions = _parseObservationResponse(outcome.text!);
      if (actions == null) return;
      final now = currentTimestampSeconds();
      for (final action in actions) {
        await _applyObservationAction(
          sessionId: sessionId,
          characterId: snapshot.character.id,
          runOrdinal: runOrdinal,
          now: now,
          action: action,
        );
      }
    } finally {
      if (identical(_tokens['observation-$sessionId'], token)) {
        _tokens.remove('observation-$sessionId');
      }
    }
  }

  Future<void> _applyObservationAction({
    required String sessionId,
    required String characterId,
    required int runOrdinal,
    required int now,
    required _ParsedObservationAction action,
  }) async {
    switch (action.action) {
      case 'confirm':
        final existing = await observationRepo.findByScopeKey(
          sessionId,
          action.scopeKey,
        );
        if (existing != null && existing.status == 'active') {
          await observationRepo.confirmObservation(
            id: existing.id,
            runOrdinal: runOrdinal,
            confidence: action.confidence,
            now: now,
          );
        }
        break;
      case 'new':
        final existing = await observationRepo.findByScopeKey(
          sessionId,
          action.scopeKey,
        );
        if (existing == null) {
          await observationRepo.insertObservation(
            CardEvolutionObservation(
              id: 'observation-${generateId()}',
              sessionId: sessionId,
              characterId: characterId,
              runOrdinal: runOrdinal,
              semanticScopeKey: action.scopeKey,
              observedChange: action.observedChange,
              canonicalClaim: action.canonicalClaim,
              evidenceMessageIds: action.evidenceMessageIds,
              cardFieldPath: action.cardFieldPath,
              lorebookEntryId: action.lorebookEntryId,
              confidence: action.confidence,
              status: 'active',
              firstSeenRun: runOrdinal,
              createdAt: now,
              updatedAt: now,
            ),
          );
        }
        break;
      case 'expire':
        final existing = await observationRepo.findByScopeKey(
          sessionId,
          action.scopeKey,
        );
        if (existing != null && existing.status == 'active') {
          await observationRepo.expireObservation(existing.id, now: now);
        }
        break;
    }
  }

  Future<void> _checkPromotionsAndExpiry(
    String sessionId,
    int runOrdinal,
  ) async {
    final now = currentTimestampSeconds();
    final threshold = observationPromotionThreshold?.call() ?? 3;
    final minConfidence = observationMinConfidence?.call() ?? 0.7;
    final expiryRuns = observationExpiryRuns?.call() ?? 4;
    final promotable = await observationRepo.getPromotableObservations(
      sessionId,
      minRepeatCount: threshold,
      minConfidence: minConfidence,
    );
    for (final obs in promotable) {
      await observationRepo.promoteObservation(obs.id, now: now);
    }
    final expired = await observationRepo.getExpiryCandidates(
      sessionId,
      currentRunOrdinal: runOrdinal,
      expiryRuns: expiryRuns,
    );
    for (final obs in expired) {
      await observationRepo.expireObservation(obs.id, now: now);
    }
  }

  static List<Map<String, Object?>> _extractValidatedTargets(
    String selectedInputJson,
  ) {
    try {
      final input = jsonDecode(selectedInputJson) as Map;
      final targets = input['validatedTargets'];
      if (targets is! List) return const [];
      return [
        for (final target in targets)
          if (target is Map<String, Object?>) target,
      ];
    } catch (_) {
      return const [];
    }
  }

  static List<_ParsedObservationAction>? _parseObservationResponse(
    String output,
  ) {
    try {
      final cleaned = output
          .replaceAll(RegExp(r'^```(?:json)?\s*'), '')
          .replaceAll(RegExp(r'\s*```$'), '')
          .trim();
      final decoded = jsonDecode(cleaned);
      if (decoded is! Map) return null;
      final observations = decoded['observations'];
      if (observations is! List) return null;
      final result = <_ParsedObservationAction>[];
      for (final raw in observations) {
        if (raw is! Map) return null;
        final action = raw['action'];
        final scopeKey = raw['scopeKey'];
        final observedChange = raw['observedChange'];
        final confidence = raw['confidence'];
        if (action is! String ||
            !const {'confirm', 'new', 'expire'}.contains(action) ||
            scopeKey is! String ||
            scopeKey.isEmpty ||
            observedChange is! String ||
            observedChange.isEmpty) {
          return null;
        }
        final conf = confidence is num ? confidence.toDouble() : 0.5;
        final clampedConf = conf < 0.0
            ? 0.0
            : conf > 1.0
            ? 1.0
            : conf;
        final evidenceRaw = raw['evidenceMessageIds'];
        final evidence = evidenceRaw is List
            ? [for (final item in evidenceRaw) item.toString()]
            : const <String>[];
        result.add(
          _ParsedObservationAction(
            action: action,
            scopeKey: scopeKey,
            observedChange: observedChange,
            canonicalClaim: raw['canonicalClaim'] is String
                ? raw['canonicalClaim'] as String
                : null,
            evidenceMessageIds: evidence,
            cardFieldPath: raw['cardFieldPath'] is String
                ? raw['cardFieldPath'] as String
                : null,
            lorebookEntryId: raw['lorebookEntryId'] is String
                ? raw['lorebookEntryId'] as String
                : null,
            confidence: clampedConf,
          ),
        );
      }
      return result;
    } catch (_) {
      return null;
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
    final preview = compact.length > 240
        ? '${compact.substring(0, 240)}...'
        : compact;
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

final class _ParsedObservationAction {
  const _ParsedObservationAction({
    required this.action,
    required this.scopeKey,
    required this.observedChange,
    required this.canonicalClaim,
    required this.evidenceMessageIds,
    required this.cardFieldPath,
    required this.lorebookEntryId,
    required this.confidence,
  });

  final String action;
  final String scopeKey;
  final String observedChange;
  final String? canonicalClaim;
  final List<String> evidenceMessageIds;
  final String? cardFieldPath;
  final String? lorebookEntryId;
  final double confidence;
}

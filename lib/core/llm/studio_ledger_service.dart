import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../db/repositories/character_knowledge_fact_repo.dart';
import '../db/repositories/character_repo.dart';
import '../db/repositories/chat_repo.dart';
import '../db/repositories/ledger_reconciliation_checkpoint_repo.dart';
import '../db/repositories/ledger_reconciliation_run_repo.dart';
import '../db/repositories/memory_book_repo.dart';
import '../db/repositories/tracker_repo.dart';
import '../db/repositories/tracker_snapshot_repo.dart';
import '../models/agent_operation_record.dart';
import '../models/character_knowledge_fact.dart';
import '../models/character.dart';
import '../models/chat_message.dart';
import '../models/memory_book.dart';
import '../models/knowledge_cleanup.dart';
import '../models/pipeline_settings.dart';
import '../models/studio_config.dart';
import '../models/studio_ledger_export.dart';
import '../models/tracker.dart';
import '../utils/id_generator.dart';
import '../utils/cast_helpers.dart';
import '../services/card_rewriter/effective_canon_context_loader.dart';
import 'aux_llm_client.dart';
import 'ledger/ledger_op_applier.dart';
import 'knowledge_cleanup_parser.dart';
import 'macro_engine.dart';
import 'studio/studio_aux_prompt_assembler.dart';
import 'studio_ledger_export_parser.dart';
import 'studio_ledger_prompt.dart';
import 'studio_ledger_reconciliation.dart';

export 'ledger/ledger_op_applier.dart';

const _ledgerSystemPromptBlockId = 'ledger_system';

// ─────────────────────────────────────────────────────────────────────────────
// StudioLedgerService
//
// Runs the Studio Ledger after each final assistant response (after the
// POST-cleaner when enabled). Maintains compact continuity state so long-
// running chats do not reset NPCs to card baseline.
//
// Pipeline placement: after final assistant text is settled —
//   1. Assistant response saved.
//   2. POST-cleaner runs if enabled.
//   3. User auto InfBlocks run if configured.
//   4. Studio Ledger runs on final cleaned text. ← this service
//   5. Visible ledger returned for internal diagnostics.
//   6. Export parsed and validated.
//   7. Entity/relationship/arc/world/scene state written to tracker namespace.
//   8. Snapshot of tracker state saved for rollback/swipe safety.
// Ledger must not run on pre-cleaner text. Manual user InfBlocks do not delay
// canon state writes. User InfBlocks are auxiliary evidence only — the ledger
// can read them but must not promote their contents to canon unless supported
// by the final assistant text, visible accepted chat, or existing canon.
//
// Ledger canon lives in tracker_rows → <studio_session_state>. MemoryBook
// remains a separate, user-controlled long-term range-summary workflow.
//
// Failure behaviour:
//   - Ledger failure MUST NOT fail chat generation.
//   - On export-parse failure, return the visible ledger without writes.
//   - On LLM failure, keep previous ledger. No writes.
//   - Cancelled/aborted: clean up, no writes.
// ─────────────────────────────────────────────────────────────────────────────

/// Result of a single Studio Ledger run.
class LedgerRunResult {
  final String
  status; // 'ok' | 'skipped' | 'disabled' | 'timeout' | 'error' | 'aborted'
  final String? visibleLedger;
  final int opsApplied;
  final String? error;
  final int elapsedMs;
  final List<AgentOperationAttempt> attempts;
  final String? model;

  const LedgerRunResult({
    required this.status,
    this.visibleLedger,
    this.opsApplied = 0,
    this.error,
    this.elapsedMs = 0,
    this.attempts = const [],
    this.model,
  });

  static const LedgerRunResult disabled = LedgerRunResult(status: 'disabled');
  static const LedgerRunResult skipped = LedgerRunResult(status: 'skipped');
  static const LedgerRunResult aborted = LedgerRunResult(status: 'aborted');
}

/// Studio Ledger service.
///
/// Thin orchestrator:
///   1. Resolve LLM config.
///   2. Build prompt (via [StudioLedgerPrompt]).
///   3. Call LLM (via [AuxLlmClient]).
///   4. Parse + validate (via [StudioLedgerExportParser]).
///   5. Apply ops to [TrackerRepo].
///   6. Snapshot tracker state for rollback safety.
///
/// Constructor-injected deps (no `Ref` — all repos/client are injected).
class StudioLedgerService {
  final AuxLlmClient _llm;
  final TrackerRepo _trackerRepo;
  final MemoryBookRepo _bookRepo;
  final TrackerSnapshotRepo _snapshotRepo;
  final CharacterKnowledgeFactRepo _knowledgeFactRepo;
  final LedgerReconciliationCheckpointRepo _reconciliationCheckpointRepo;
  final LedgerReconciliationRunRepo _reconciliationRunRepo;
  final CharacterRepo _characterRepo;
  final ChatRepo _chatRepo;
  final EffectiveCanonContextLoader _canonContextLoader;
  final StudioLedgerExportParser _parser;
  final StudioLedgerPrompt _promptBuilder;
  final LedgerOpApplier _opApplier;

  StudioLedgerService({
    required this._llm,
    required this._trackerRepo,
    required this._bookRepo,
    required this._snapshotRepo,
    required this._knowledgeFactRepo,
    required this._reconciliationCheckpointRepo,
    required this._reconciliationRunRepo,
    required this._characterRepo,
    required this._chatRepo,
    required this._canonContextLoader,
  }) : _parser = const StudioLedgerExportParser(),
       _promptBuilder = const StudioLedgerPrompt(),
       _opApplier = const LedgerOpApplier();

  Future<LedgerRunResult> reconcile({
    required String sessionId,
    required PipelineSettings settings,
    required AuxApiConfig config,
    required LedgerReconciliationPlan plan,
    List<StudioPresetBlock> ledgerBlocks = const [],
    MacroContext? macroCtx,
    FutureOr<bool> Function()? isStillCurrent,
    CancelToken? cancelToken,
  }) async {
    final token = cancelToken ?? CancelToken();
    if (token.isCancelled || await _isStillCurrent(isStillCurrent) == false) {
      return LedgerRunResult.aborted;
    }
    final sw = Stopwatch()..start();
    try {
      final canon = await _loadCanonContext(sessionId);
      await _throwIfReconciliationAborted(token, isStillCurrent);
      final endpointSnapshot = await _snapshotRepo.getByAnchor(
        sessionId: sessionId,
        messageId: plan.endMessage.id,
        swipeId: plan.endMessage.swipeId,
        agentSwipeId: plan.endMessage.agentSwipeId,
      );
      await _throwIfReconciliationAborted(token, isStillCurrent);
      if (endpointSnapshot == null || !endpointSnapshot.committed) {
        return LedgerRunResult(
          status: 'skipped',
          error: 'review endpoint snapshot is not committed',
          elapsedMs: sw.elapsedMilliseconds,
        );
      }

      final promptTrackers = _promptTrackers(canon.context);
      final reviewMessageIds = plan.messageIds.toSet();
      final reviewableFacts = canon.context.resolution.activeFacts;
      final promptFacts = reviewableFacts
          .where((fact) => reviewMessageIds.contains(fact.sourceMessageId))
          .toList();
      final duplicateRetractions = exactDuplicateKnowledgeRetractions(
        reviewableFacts,
      );
      final staleAnchorRetractions = staleKnowledgeAnchorRetractions(
        reviewableFacts,
        plan.messages,
      );
      await _throwIfReconciliationAborted(token, isStillCurrent);
      final promptBlock = ledgerBlocks
          .where(
            (block) =>
                block.id == ledgerReconciliationPromptBlockId &&
                block.enabled &&
                block.injectionPoint == 'ledger' &&
                block.content.trim().isNotEmpty,
          )
          .firstOrNull;
      final systemPrompt = promptBlock == null
          ? fallbackLedgerReconciliationPrompt
          : macroCtx == null
          ? promptBlock.content
          : replaceMacros(promptBlock.content, macroCtx).text;
      const reconciliationPrompt = StudioLedgerReconciliationPrompt();
      final reviewText = plan.messages
          .map((message) => message.content)
          .join('\n');
      final offeredFacts = reconciliationPrompt.relevantKnowledgeFacts(
        promptFacts,
        reviewText,
      );
      final prompt = reconciliationPrompt.build(
        systemPrompt: systemPrompt,
        plan: plan,
        trackers: promptTrackers,
        knowledgeFacts: offeredFacts,
        character: canon.source,
      );
      await _throwIfReconciliationAborted(token, isStillCurrent);
      final outcome = await _llm.callOnceWithLog(
        config: config,
        prompt: prompt,
        maxTokens: settings.ledger.studioLedgerMaxTokens > 0
            ? settings.ledger.studioLedgerMaxTokens
            : 15000,
        temperature: settings.ledger.studioLedgerTemperature >= 0
            ? settings.ledger.studioLedgerTemperature
            : 0.2,
        timeoutMs: _llm.resolveLedgerTimeout(settings),
        cancelToken: token,
        omitReasoning: true,
      );
      if (token.isCancelled || await _isStillCurrent(isStillCurrent) == false) {
        return LedgerRunResult.aborted;
      }
      if (!await _isCanonStillCurrent(sessionId, canon)) {
        return LedgerRunResult.aborted;
      }
      if (!outcome.isOk || outcome.text == null || outcome.text!.isEmpty) {
        final attempt = outcome.attempts.lastOrNull;
        return LedgerRunResult(
          status: 'error',
          error: 'Reconciliation LLM call failed: ${attempt?.status}',
          elapsedMs: sw.elapsedMilliseconds,
          attempts: outcome.attempts,
          model: config.model,
        );
      }

      final parsed = _parser.parse(outcome.text!);
      final isEmptyExport =
          parsed.rejectionReason == 'empty export (no ops or knowledge facts)';
      if (!parsed.hasExport && !isEmptyExport) {
        return LedgerRunResult(
          status: 'error',
          visibleLedger: parsed.visibleLedger,
          error: parsed.rejectionReason,
          elapsedMs: sw.elapsedMilliseconds,
          attempts: outcome.attempts,
          model: config.model,
        );
      }
      final export = parsed.export ?? const StudioLedgerExport();
      if (export.knowledgeFacts.isNotEmpty) {
        return LedgerRunResult(
          status: 'error',
          error: 'Reconciliation must not emit knowledgeFacts',
          elapsedMs: sw.elapsedMilliseconds,
          attempts: outcome.attempts,
          model: config.model,
        );
      }
      if (token.isCancelled || await _isStillCurrent(isStillCurrent) == false) {
        return LedgerRunResult.aborted;
      }
      const cleanupParser = KnowledgeCleanupParser();
      if (!cleanupParser.hasValidBlock(outcome.text!)) {
        return LedgerRunResult(
          status: 'error',
          error: 'Reconciliation returned no valid knowledge cleanup block',
          elapsedMs: sw.elapsedMilliseconds,
          attempts: outcome.attempts,
          model: config.model,
        );
      }
      final cleanupOps =
          cleanupParser.parse(
              output: outcome.text!,
              offeredFacts: offeredFacts,
              reviewText: reviewText,
            )
            ..addAll(duplicateRetractions)
            ..addAll(staleAnchorRetractions);
      final allowedCleanupFactIds = {
        ...offeredFacts.map((fact) => fact.id),
        ...duplicateRetractions.map((op) => op.factId),
        ...staleAnchorRetractions.map((op) => op.factId),
      };
      final anchors = plan.messages
          .map(
            (message) => ReconciliationAnchor(
              messageId: message.id,
              swipeId: message.swipeId,
              agentSwipeId: message.agentSwipeId,
              role: message.role,
              contentHash: computeHash(message.content),
            ),
          )
          .toList(growable: false);
      final canonicalResult = <String, dynamic>{
        'cleanupOps': cleanupOps.map(_cleanupOpJson).toList(growable: false),
        'export': jsonDecode(jsonEncode(export.toJson())),
      };
      final intendedOps = <String>[
        ...export.ops.map((op) => 'tracker:${op.op}:${op.key}'),
        ...cleanupOps.map(_cleanupOpMetadata),
      ];

      var opsApplied = 0;
      var replayed = false;
      await _trackerRepo.db.transaction(() async {
        await _throwIfLedgerCommitStale(
          sessionId: sessionId,
          canon: canon,
          token: token,
          isStillCurrent: isStillCurrent,
          target: _LedgerTarget.fromMessage(plan.endMessage),
          requireCommittedSnapshot: true,
        );
        final manifestRefs = await _reconciliationRunRepo
            .readAcceptedManifestRefs(sessionId: sessionId, anchors: anchors);
        final candidate = LedgerReconciliationRun(
          id: '',
          sessionId: sessionId,
          ordinal: 1,
          anchors: anchors,
          acceptedManifestRefs: manifestRefs,
          effectiveCanonStamp: canon.context.stamp.identity,
          effectiveCanonRevision: canon.context.effectiveRevision.number,
          effectiveCanonHash: canon.context.effectiveRevision.hash,
          canonicalResult: canonicalResult,
          predecessorChainHash: '',
          contractVersion: 1,
          opsApplied: intendedOps,
          createdAt: 0,
        );
        // The ID covers immutable candidate content, so a canon change appends
        // rather than colliding with an earlier identical plan/LLM output.
        final draft = LedgerReconciliationRun(
          id: 'reconciliation-${candidate.contentHash}',
          sessionId: candidate.sessionId,
          ordinal: candidate.ordinal,
          anchors: candidate.anchors,
          acceptedManifestRefs: candidate.acceptedManifestRefs,
          effectiveCanonStamp: candidate.effectiveCanonStamp,
          effectiveCanonRevision: candidate.effectiveCanonRevision,
          effectiveCanonHash: candidate.effectiveCanonHash,
          canonicalResult: candidate.canonicalResult,
          predecessorChainHash: candidate.predecessorChainHash,
          contractVersion: candidate.contractVersion,
          opsApplied: candidate.opsApplied,
          createdAt: candidate.createdAt,
        );
        final append = await _reconciliationRunRepo.appendCandidate(draft);
        if (append is ReconciliationRunIdempotent) {
          replayed = true;
          return;
        }
        if (append is! ReconciliationRunAppended) {
          throw StateError('Unable to append reconciliation run: $append');
        }
        await _trackerRepo.replaceLedgerState(
          sessionId,
          _stampedBaseTrackers(canon, promptTrackers),
        );
        for (final op in export.ops) {
          await _throwIfLedgerCommitStale(
            sessionId: sessionId,
            canon: canon,
            token: token,
            isStillCurrent: isStillCurrent,
            target: _LedgerTarget.fromMessage(plan.endMessage),
          );
          await _opApplier.applyOp(
            op: op,
            sessionId: sessionId,
            messageId: plan.endMessage.id,
            swipeId: plan.endMessage.swipeId,
            agentSwipeId: plan.endMessage.agentSwipeId,
            trackerRepo: _trackerRepo,
            basisRevisionNumber: canon.context.effectiveRevision.number,
            basisRevisionHash: canon.context.effectiveRevision.hash,
          );
          opsApplied++;
        }
        await _throwIfLedgerCommitStale(
          sessionId: sessionId,
          canon: canon,
          token: token,
          isStillCurrent: isStillCurrent,
          target: _LedgerTarget.fromMessage(plan.endMessage),
        );
        opsApplied += await _knowledgeFactRepo.applyReconciliationCleanup(
          sessionId: sessionId,
          ops: cleanupOps,
          allowedFactIds: allowedCleanupFactIds,
          endpointMessageId: plan.endMessage.id,
          messageIds: plan.messageIds,
        );
        await _throwIfLedgerCommitStale(
          sessionId: sessionId,
          canon: canon,
          token: token,
          isStillCurrent: isStillCurrent,
          target: _LedgerTarget.fromMessage(plan.endMessage),
          checkCanon: false,
        );
        final updated = await _trackerRepo.getBySessionId(sessionId);
        await _throwIfLedgerCommitStale(
          sessionId: sessionId,
          canon: canon,
          token: token,
          isStillCurrent: isStillCurrent,
          target: _LedgerTarget.fromMessage(plan.endMessage),
          checkCanon: false,
        );
        await _snapshotRepo.upsertTrackers(
          sessionId: sessionId,
          messageId: plan.endMessage.id,
          swipeId: plan.endMessage.swipeId,
          agentSwipeId: plan.endMessage.agentSwipeId,
          trackers: updated,
          committed: true,
        );
        await _throwIfReconciliationAborted(token, isStillCurrent);
        await _reconciliationCheckpointRepo.upsert(
          LedgerReconciliationCheckpoint(
            sessionId: sessionId,
            startMessageId: plan.startMessageId,
            endMessageId: plan.endMessage.id,
            endSwipeId: plan.endMessage.swipeId,
            endAgentSwipeId: plan.endMessage.agentSwipeId,
            messageIds: plan.messageIds,
            rangeHash: plan.rangeHash,
          ),
        );
        await _throwIfLedgerCommitStale(
          sessionId: sessionId,
          canon: canon,
          token: token,
          isStillCurrent: isStillCurrent,
          target: _LedgerTarget.fromMessage(plan.endMessage),
          checkCanon: false,
        );
      });
      return LedgerRunResult(
        status: 'ok',
        visibleLedger: parsed.visibleLedger,
        opsApplied: replayed ? 0 : opsApplied,
        elapsedMs: sw.elapsedMilliseconds,
        attempts: outcome.attempts,
        model: config.model,
      );
    } on _LedgerCommitStale {
      return LedgerRunResult.aborted;
    } catch (e) {
      if (token.isCancelled || (e is DioException && CancelToken.isCancel(e))) {
        return LedgerRunResult.aborted;
      }
      debugPrint('[StudioLedger] reconciliation failed: $e');
      return LedgerRunResult(
        status: 'error',
        error: '$e',
        elapsedMs: sw.elapsedMilliseconds,
      );
    }
  }

  Future<void> _throwIfReconciliationAborted(
    CancelToken token,
    FutureOr<bool> Function()? isStillCurrent,
  ) async {
    if (token.isCancelled || await _isStillCurrent(isStillCurrent) == false) {
      throw const _LedgerReconciliationAborted();
    }
  }

  /// Run the Studio Ledger for [sessionId] on [finalAssistantText].
  ///
  /// [messageId], [swipeId], [agentSwipeId] are the provenance anchor for
  /// state writes — required for rollback.
  ///
  /// [isStillCurrent] is called before each write; returns false when a newer
  /// generation has started (abort guard).
  ///
  /// Never throws — all errors are captured in [LedgerRunResult].
  Future<LedgerRunResult> run({
    required String sessionId,
    required PipelineSettings settings,
    required AuxApiConfig config,
    required String finalAssistantText,
    required String recentHistoryText,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
    bool forceEnabled = false,
    FutureOr<bool> Function()? isStillCurrent,
    CancelToken? cancelToken,
    List<StudioPresetBlock> ledgerBlocks = const [],
    MacroContext? macroCtx,
    bool commitSnapshot = false,
  }) async {
    // Studio Ledger is always-on when Studio is enabled. forceEnabled is
    // still respected for manual triggers.

    if (finalAssistantText.trim().isEmpty) {
      debugPrint('[StudioLedger] skipping — empty assistant text');
      return LedgerRunResult.skipped;
    }

    final token = cancelToken ?? CancelToken();
    if (token.isCancelled) return LedgerRunResult.aborted;

    final sw = Stopwatch()..start();

    try {
      // ── 1. LLM config is resolved by the caller via StudioSlotResolver ──
      if (token.isCancelled || await _isStillCurrent(isStillCurrent) == false) {
        return LedgerRunResult.aborted;
      }

      // ── 2. Load prompt base (committed canon + live manual overrides) ────
      final canon = await _loadCanonContext(sessionId);
      final promptTrackers = _promptTrackers(canon.context);
      final book = await _bookRepo.getBySessionId(sessionId);
      final recentEntries =
          book?.entries.where((e) => e.status == 'active').take(20).toList() ??
          const <MemoryEntry>[];

      if (token.isCancelled || await _isStillCurrent(isStillCurrent) == false) {
        return LedgerRunResult.aborted;
      }
      if (!await _isCanonStillCurrent(sessionId, canon)) {
        return LedgerRunResult.aborted;
      }

      // ── 3. Build prompt ─────────────────────────────────────────────────
      final prompt = _buildLedgerPrompt(
        finalAssistantText: finalAssistantText,
        recentHistoryText: recentHistoryText,
        currentTrackers: promptTrackers,
        recentMemoryEntries: recentEntries,
        ledgerBlocks: ledgerBlocks,
        macroCtx: macroCtx,
        character: canon.source,
      );

      debugPrint(
        '[StudioLedger] prompt session=$sessionId '
        'chars=${prompt.length} '
        'usingPresetBlocks=${ledgerBlocks.isNotEmpty && macroCtx != null} '
        'first500=${prompt.length > 500 ? prompt.substring(0, 500) : prompt}',
      );

      // ── 4. Call LLM ─────────────────────────────────────────────────────
      final maxTokens = settings.ledger.studioLedgerMaxTokens > 0
          ? settings.ledger.studioLedgerMaxTokens
          : 15000;
      final temperature = settings.ledger.studioLedgerTemperature >= 0
          ? settings.ledger.studioLedgerTemperature
          : 0.2;
      final timeoutMs = _llm.resolveLedgerTimeout(settings);

      debugPrint(
        '[StudioLedger] starting session=$sessionId '
        'model=${config.model} '
        'timeoutMs=$timeoutMs '
        'textChars=${finalAssistantText.length}',
      );

      final outcome = await _llm.callOnceWithLog(
        config: config,
        prompt: prompt,
        maxTokens: maxTokens,
        temperature: temperature,
        timeoutMs: timeoutMs,
        cancelToken: token,
        omitReasoning: true,
      );

      if (token.isCancelled || await _isStillCurrent(isStillCurrent) == false) {
        return LedgerRunResult.aborted;
      }

      if (!outcome.isOk || outcome.text == null || outcome.text!.isEmpty) {
        final lastAttempt = outcome.attempts.lastOrNull;
        debugPrint(
          '[StudioLedger] LLM call failed session=$sessionId '
          'status=${lastAttempt?.status} '
          'statusCode=${lastAttempt?.statusCode ?? 0} '
          'elapsedMs=${lastAttempt?.elapsedMs ?? 0} '
          'error=${lastAttempt?.error ?? "none"}',
        );
        return LedgerRunResult(
          status: 'error',
          error:
              'LLM call failed: ${lastAttempt?.status}'
              '${lastAttempt?.error != null ? ': ${lastAttempt!.error}' : ''}',
          elapsedMs: sw.elapsedMilliseconds,
          attempts: outcome.attempts,
          model: config.model,
        );
      }

      // ── 5. Parse + validate ─────────────────────────────────────────────
      final rawResponse = outcome.text!;
      debugPrint(
        '[StudioLedger] raw response session=$sessionId '
        'chars=${rawResponse.length} '
        'first1000=${rawResponse.length > 1000 ? rawResponse.substring(0, 1000) : rawResponse}',
      );

      final parseResult = _parser.parse(rawResponse);

      debugPrint(
        '[StudioLedger] parsed session=$sessionId '
        'hasExport=${parseResult.hasExport} '
        'visibleLedgerChars=${parseResult.visibleLedger.length} '
        'rejection=${parseResult.rejectionReason ?? "none"}',
      );

      if (!parseResult.hasExport && !_isNoWriteLedgerOutput(parseResult)) {
        return LedgerRunResult(
          status: 'error',
          visibleLedger: parseResult.visibleLedger,
          error: parseResult.rejectionReason,
          elapsedMs: sw.elapsedMilliseconds,
          attempts: outcome.attempts,
          model: config.model,
        );
      }

      if (token.isCancelled || await _isStillCurrent(isStillCurrent) == false) {
        return LedgerRunResult.aborted;
      }

      // ── 6. Apply ops to tracker namespace ───────────────────────────────
      final export = parseResult.export ?? const StudioLedgerExport();
      var opsApplied = 0;
      final target = _LedgerTarget(
        messageId: messageId,
        swipeId: swipeId,
        agentSwipeId: agentSwipeId,
        content: finalAssistantText,
      );
      final facts = export.knowledgeFacts
          .map(
            (fact) => CharacterKnowledgeFact(
              id: generateId(),
              chatSessionId: sessionId,
              knowerKey: fact.knowerKey,
              knowerName: fact.knowerName,
              subjectKey: fact.subjectKey,
              subjectName: fact.subjectName,
              factClass: CharacterKnowledgeFactClass.fromWireName(
                fact.factClass,
              ),
              scopeKey: fact.scopeKey,
              predicate: fact.predicate,
              object: fact.object,
              epistemicState: CharacterKnowledgeEpistemicState.fromWireName(
                fact.epistemicState,
              ),
              confidence: fact.confidence,
              importance: fact.importance,
              entities: fact.entities,
              topics: fact.topics,
              sourceMessageId: messageId,
              sourceSwipeId: swipeId,
              sourceAgentSwipeId: agentSwipeId,
              supersedesId: fact.supersedesId,
              basisRevisionNumber: canon.context.effectiveRevision.number,
              basisRevisionHash: canon.context.effectiveRevision.hash,
            ),
          )
          .toList(growable: false);
      await _trackerRepo.db.transaction(() async {
        await _throwIfLedgerCommitStale(
          sessionId: sessionId,
          canon: canon,
          token: token,
          isStillCurrent: isStillCurrent,
          target: target,
        );
        // Rebuild model-owned state from committed canon before this patch.
        await _trackerRepo.replaceLedgerState(
          sessionId,
          _stampedBaseTrackers(canon, promptTrackers),
        );
        for (final op in export.ops) {
          await _throwIfLedgerCommitStale(
            sessionId: sessionId,
            canon: canon,
            token: token,
            isStillCurrent: isStillCurrent,
            target: target,
          );
          await _opApplier.applyOp(
            op: op,
            sessionId: sessionId,
            messageId: messageId,
            swipeId: swipeId,
            agentSwipeId: agentSwipeId,
            trackerRepo: _trackerRepo,
            basisRevisionNumber: canon.context.effectiveRevision.number,
            basisRevisionHash: canon.context.effectiveRevision.hash,
          );
          opsApplied++;
        }
        await _throwIfLedgerCommitStale(
          sessionId: sessionId,
          canon: canon,
          token: token,
          isStillCurrent: isStillCurrent,
          target: target,
        );
        await _knowledgeFactRepo.replaceTentativeAnchor(
          sessionId: sessionId,
          messageId: messageId,
          swipeId: swipeId,
          agentSwipeId: agentSwipeId,
          facts: facts,
        );
        await _throwIfLedgerCommitStale(
          sessionId: sessionId,
          canon: canon,
          token: token,
          isStillCurrent: isStillCurrent,
          target: target,
          checkCanon: false,
        );
        final updatedTrackers = await _trackerRepo.getBySessionId(sessionId);
        await _snapshotRepo.upsertTrackers(
          sessionId: sessionId,
          messageId: messageId,
          swipeId: swipeId,
          agentSwipeId: agentSwipeId,
          trackers: updatedTrackers,
          committed: commitSnapshot,
        );
        await _throwIfLedgerCommitStale(
          sessionId: sessionId,
          canon: canon,
          token: token,
          isStillCurrent: isStillCurrent,
          target: target,
          checkCanon: false,
        );
      });

      debugPrint(
        '[StudioLedger] applied $opsApplied/${export.ops.length} ops session=$sessionId',
      );

      sw.stop();
      debugPrint(
        '[StudioLedger] done session=$sessionId '
        'ops=$opsApplied '
        'elapsedMs=${sw.elapsedMilliseconds}',
      );

      return LedgerRunResult(
        status: 'ok',
        visibleLedger: parseResult.visibleLedger,
        opsApplied: opsApplied,
        elapsedMs: sw.elapsedMilliseconds,
        attempts: outcome.attempts,
        model: config.model,
      );
    } on _LedgerCommitStale {
      return LedgerRunResult.aborted;
    } on TimeoutException {
      sw.stop();
      debugPrint('[StudioLedger] timeout session=$sessionId');
      return LedgerRunResult(
        status: 'timeout',
        elapsedMs: sw.elapsedMilliseconds,
      );
    } catch (e) {
      sw.stop();
      if (token.isCancelled || (e is DioException && CancelToken.isCancel(e))) {
        return LedgerRunResult.aborted;
      }
      debugPrint('[StudioLedger] error session=$sessionId: $e');
      return LedgerRunResult(
        status: 'error',
        error: '$e',
        elapsedMs: sw.elapsedMilliseconds,
      );
    }
  }

  /// Builds the ledger prompt from preset blocks when available, falling
  /// back to [StudioLedgerPrompt] when no preset blocks are supplied.
  /// The output structure template (`<glaze_memory_export>` +
  /// `<studio_ledger>`) is always code-appended — the parser depends on it.
  String _buildLedgerPrompt({
    required String finalAssistantText,
    required String recentHistoryText,
    required List<Tracker> currentTrackers,
    required List<MemoryEntry> recentMemoryEntries,
    List<StudioPresetBlock> ledgerBlocks = const [],
    MacroContext? macroCtx,
    Character? character,
  }) {
    final hasActiveLedgerBlocks = ledgerBlocks.any(
      (block) =>
          block.id == _ledgerSystemPromptBlockId &&
          block.enabled &&
          block.injectionPoint == 'ledger' &&
          block.content.trim().isNotEmpty,
    );
    if (!hasActiveLedgerBlocks || macroCtx == null) {
      return _promptBuilder.build(
        finalAssistantText: finalAssistantText,
        recentHistoryText: recentHistoryText,
        currentTrackers: currentTrackers,
        recentMemoryEntries: recentMemoryEntries,
        character: character,
      );
    }

    final trackerBlock = _promptBuilder.buildCurrentStateBlock(
      currentTrackers,
      '$recentHistoryText\n$finalAssistantText',
    );
    final keyCatalog = _promptBuilder.buildExistingKeyCatalog(currentTrackers);
    final memoryBlock = _buildMemoryBlock(recentMemoryEntries);
    final cardSection = StudioLedgerPrompt.buildCharacterCardSection(character);

    final runtimeSuffix =
        '''
$cardSection<current_state>
$trackerBlock
</current_state>

<existing_keys>
$keyCatalog
</existing_keys>

<existing_memory>
$memoryBlock
</existing_memory>

<recent_chat>
$recentHistoryText
</recent_chat>

<final_assistant_response>
$finalAssistantText
</final_assistant_response>

Now produce the Studio Ledger output. You MUST return BOTH blocks below.
The <glaze_memory_export> block is MANDATORY — even when there is nothing
to write, include it with empty arrays. Do not omit it under any circumstance.

Required response template (follow this exact structure):
<glaze_memory_export>
{"ops":[],"knowledgeFacts":[]}
</glaze_memory_export>
<studio_ledger>
Compact continuity snapshot here.
</studio_ledger>

The <glaze_memory_export> block MUST come first, before <studio_ledger>.
It must contain a single JSON object with "ops" and "knowledgeFacts" arrays.
When there are no state changes or knowledge facts, output empty arrays —
do NOT skip the block.

Ops format:
{"ops":[{"op":"set","key":"npc:Name.field","value":"…","evidence":"…","eventState":"completed"},…],"knowledgeFacts":[]}

Allowed namespaces: npc:, relationship:, arc:, world:, scene.
Allowed ops: set, delete. Every set REPLACES the complete current value.
Never append history to a state value. Keep each value under 1200 characters.
Never write npc:*.knowledge or relationship:*.knowledge; durable propositions belong in knowledgeFacts.
Relationship trust/status/attitude and card overrides are current state and must be updated with set whenever they change.
Reuse an exact key from <current_state> or <existing_keys> for the same fact; update it with set instead of creating a synonym key.
Allowed eventState: planned, suggested, threatened, attempted, completed, failed, cancelled, unknown (or omit).''';

    return const StudioAuxPromptAssembler().assemble(
      blocks: ledgerBlocks,
      injectionPoint: 'ledger',
      macroCtx: macroCtx,
      runtimeSuffix: runtimeSuffix,
      skipBlockIds: {
        for (final block in ledgerBlocks)
          if (block.id != _ledgerSystemPromptBlockId) block.id,
      },
    );
  }

  String _buildMemoryBlock(List<MemoryEntry> entries) {
    if (entries.isEmpty) return '(no existing memory)';
    return entries
        .take(20)
        .map((e) {
          final keys = e.keys.isEmpty ? '' : ' [${e.keys.join(', ')}]';
          final locked = e.locked ? ' [locked]' : '';
          return '- ${e.title.isNotEmpty ? e.title : e.id}$keys$locked';
        })
        .join('\n');
  }

  bool _isNoWriteLedgerOutput(LedgerParseResult parseResult) {
    final reason = parseResult.rejectionReason ?? '';
    if (reason == 'no <glaze_memory_export> block found') return true;
    if (reason == 'empty export (no ops or knowledge facts)') {
      return true;
    }
    return false;
  }

  Future<_LedgerCanonContext> _loadCanonContext(String sessionId) async {
    final session = await _chatRepo.getById(sessionId);
    if (session == null) {
      throw StateError('Ledger session not found: $sessionId');
    }
    final source = await _characterRepo.getById(session.characterId);
    if (source == null) {
      throw StateError(
        'Ledger source character not found: ${session.characterId}',
      );
    }
    final context = await _canonContextLoader.load(
      sessionId: sessionId,
      sourceCharacter: source,
    );
    return _LedgerCanonContext(source, context);
  }

  Future<bool> _isCanonStillCurrent(
    String sessionId,
    _LedgerCanonContext canon,
  ) async {
    final currentSource = await _characterRepo.getById(canon.source.id);
    if (currentSource == null) return false;
    return _canonContextLoader.isStillCurrentReadOnly(
      sessionId: sessionId,
      sourceCharacter: currentSource,
      stamp: canon.context.stamp,
    );
  }

  Future<bool> _isStillCurrent(FutureOr<bool> Function()? guard) async =>
      await guard?.call() ?? true;

  /// Transactional commit fence. It deliberately uses the loader's read-only
  /// comparison so a stale check can never append a character revision.
  Future<void> _throwIfLedgerCommitStale({
    required String sessionId,
    required _LedgerCanonContext canon,
    required CancelToken token,
    required FutureOr<bool> Function()? isStillCurrent,
    required _LedgerTarget target,
    bool requireCommittedSnapshot = false,
    bool checkCanon = true,
  }) async {
    if (token.isCancelled || await _isStillCurrent(isStillCurrent) == false) {
      throw const _LedgerCommitStale();
    }
    if (checkCanon && !await _isCanonStillCurrent(sessionId, canon)) {
      throw const _LedgerCommitStale();
    }
    final session = await _chatRepo.getById(sessionId);
    final message = session?.messages
        .where((item) => item.id == target.messageId)
        .firstOrNull;
    if (message == null ||
        message.swipeId != target.swipeId ||
        message.agentSwipeId != target.agentSwipeId ||
        message.content != target.content) {
      throw const _LedgerCommitStale();
    }
    if (requireCommittedSnapshot) {
      final snapshot = await _snapshotRepo.getByAnchor(
        sessionId: sessionId,
        messageId: target.messageId,
        swipeId: target.swipeId,
        agentSwipeId: target.agentSwipeId,
      );
      if (snapshot == null || !snapshot.committed) {
        throw const _LedgerCommitStale();
      }
    }
  }

  List<Tracker> _stampedBaseTrackers(
    _LedgerCanonContext canon,
    List<Tracker> trackers,
  ) => trackers
      .map(
        (tracker) => Tracker(
          sessionId: tracker.sessionId,
          name: tracker.name,
          value: tracker.value,
          scope: tracker.scope,
          provenance: tracker.provenance,
          basisRevisionNumber: canon.context.effectiveRevision.number,
          basisRevisionHash: canon.context.effectiveRevision.hash,
          updatedAt: tracker.updatedAt,
        ),
      )
      .toList(growable: false);

  List<Tracker> _promptTrackers(EffectiveCanonContext context) => [
    ...context.resolution.activeTrackers,
    ...context.manualControls,
  ];

  Map<String, dynamic> _cleanupOpJson(KnowledgeCleanupOp op) => {
    'type': op.type.name,
    if (op.factId.isNotEmpty) 'factId': op.factId,
    if (op.fromKey.isNotEmpty) 'fromKey': op.fromKey,
    if (op.toKey.isNotEmpty) 'toKey': op.toKey,
    if (op.canonicalName.isNotEmpty) 'canonicalName': op.canonicalName,
  };

  String _cleanupOpMetadata(KnowledgeCleanupOp op) => switch (op.type) {
    KnowledgeCleanupOpType.retract => 'cleanup:retract:${op.factId}',
    KnowledgeCleanupOpType.renameEntity =>
      'cleanup:rename:${op.fromKey}:${op.toKey}:${op.canonicalName}',
  };
}

class _LedgerCanonContext {
  const _LedgerCanonContext(this.source, this.context);
  final Character source;
  final EffectiveCanonContext context;
}

class _LedgerReconciliationAborted implements Exception {
  const _LedgerReconciliationAborted();
}

class _LedgerCommitStale implements Exception {
  const _LedgerCommitStale();
}

class _LedgerTarget {
  const _LedgerTarget({
    required this.messageId,
    required this.swipeId,
    required this.agentSwipeId,
    required this.content,
  });

  factory _LedgerTarget.fromMessage(ChatMessage message) => _LedgerTarget(
    messageId: message.id,
    swipeId: message.swipeId,
    agentSwipeId: message.agentSwipeId,
    content: message.content,
  );

  final String messageId;
  final int swipeId;
  final int agentSwipeId;
  final String content;
}

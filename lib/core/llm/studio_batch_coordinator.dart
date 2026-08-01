import 'package:dio/dio.dart';

import '../models/api_config.dart';
import '../models/studio_config.dart';
import 'agent_runner.dart';
import 'studio_message_builder.dart';
import 'tracker_batcher.dart';
import 'studio_turn_config_snapshot.dart';
import 'studio/studio_context.dart';

/// Runs a batch group of Studio chat-time trackers: builds the batched
/// system prompt + per-agent task text, fires a single LLM request, parses
/// the `<result>` blocks, and retries the whole batch twice before surfacing
/// tracker failures to the Studio pipeline. Extracted from `MemoryStudioService`
/// (plan §2.9).
///
/// Deps: the injected [TrackerBatcher], [AgentRunner], and
/// [StudioMessageBuilder]. `_log` is injected as a callback so this specialist
/// does not own the host's debug-print sink.
class StudioBatchCoordinator {
  final TrackerBatcher _batcher;
  final AgentRunner _runner;
  final StudioMessageBuilder _messageBuilder;
  final void Function(String message) _log;

  StudioBatchCoordinator(
    this._batcher,
    this._runner,
    this._messageBuilder,
    this._log,
  );

  /// [batchContextSize] = max contextSize across the group), per-agent task
  /// text, the batched system prompt, fire a single LLM request, parse the
  /// `<result>` blocks, and retry the batch twice for any transport failure or
  /// missing/unparseable tracker result. Exhausted retries return failed
  /// tracker results; the caller turns that into a hard Studio error.
  Future<List<TrackerBatchResult>> runBatchGroup({
    required TrackerBatchGroup group,
    required StudioConfig config,
    required StudioPreset studioPreset,
    required StudioContext context,
    required ApiConfig apiConfig,
    required String sessionId,
    required CancelToken cancelToken,
    required int batchContextSize,
    String? apiConfigId,
    StudioTurnConfigSnapshot? turnConfig,
  }) async {
    final sharedMessages = _messageBuilder.buildSharedBatchMessages(
      context: context,
      batchContextSize: batchContextSize,
    );
    final perAgentTask = <String, String>{};
    for (final agent in group.agents) {
      perAgentTask[agent.id] = _messageBuilder.buildPerAgentTaskText(
        agent: agent,
        config: config,
        studioPreset: studioPreset,
        context: context,
      );
    }
    final roleText = _messageBuilder.batchRoleText(
      config,
      studioPreset,
      context,
    );
    final systemPrompt = _batcher.buildBatchSystemPrompt(
      group: group,
      sharedMessages: sharedMessages,
      perAgentTaskText: perAgentTask,
      roleText: roleText,
    );
    final batchMessages = <Map<String, dynamic>>[
      {'role': 'system', 'content': systemPrompt},
      {
        'role': 'user',
        'content':
            'Produce the required <result> blocks now, one per agent_task '
            'listed above, in order.',
      },
    ];
    final batchAgent = group.agents.first.copyWith(
      maxTokens: group.batchMaxTokens,
      temperature: group.batchTemperature,
      contextSize: batchContextSize,
    );
    List<TrackerBatchResult>? lastParsed;
    String? lastError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      if (cancelToken.isCancelled) {
        throw const AgentRunFailedException(
          agentId: 'batch',
          agentName: 'Studio tracker batch',
          reason: 'cancelled',
        );
      }
      try {
        final result = await _runner.runAgent(
          agent: batchAgent,
          messages: batchMessages,
          apiConfig: apiConfig,
          sessionId: sessionId,
          isFinalResponse: false,
          cancelToken: cancelToken,
          preResolvedConfig: group.resolved,
          turnConfig: turnConfig,
        );
        final parsed = _batcher.parseBatchResponse(result.text, group);
        if (_allOk(parsed)) return parsed;
        lastParsed = parsed;
        final failedCount = parsed
            .where((result) => result.status != 'ok')
            .length;
        lastError = '$failedCount tracker result(s) missing or invalid';
      } on AgentRunFailedException catch (error) {
        if (cancelToken.isCancelled) rethrow;
        lastError = error.reason;
        _log('batch ${group.key} attempt $attempt failed: $lastError');
      }
    }
    return lastParsed ??
        group.agents
            .map(
              (agent) => TrackerBatchResult.failed(
                agentId: agent.id,
                agentName: agent.name,
                reason: lastError ?? 'tracker batch failed after 2 retries',
              ),
            )
            .toList(growable: false);
  }

  bool _allOk(List<TrackerBatchResult> results) {
    return results.every((r) => r.status == 'ok' && r.text.isNotEmpty);
  }
}

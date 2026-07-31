import '../models/studio_config.dart';

/// One hard-coded agent spec slot — the fixed identity an agent is born from.
class StudioControllerSpec {
  final String id;
  final String name;
  final String purpose;
  final String outputContract;
  final String laneOwns;
  final String laneSkip;
  final String refreshPolicy;
  final List<String> invalidationSignals;
  final double temperature;
  final int maxTokens;
  final int timeoutMs;
  final bool isFinal;
  final String phase;
  final int contextSize;
  final bool lockedOn;
  final String? requiresSpecId;

  const StudioControllerSpec({
    required this.id,
    required this.name,
    required this.purpose,
    required this.outputContract,
    required this.laneOwns,
    required this.laneSkip,
    required this.refreshPolicy,
    required this.invalidationSignals,
    required this.temperature,
    required this.maxTokens,
    required this.timeoutMs,
    this.isFinal = false,
    this.phase = 'pre_generation',
    this.contextSize = 0,
    this.lockedOn = false,
    this.requiresSpecId,
  });
}

/// The fixed set of Studio controller slots + lookup helpers. Pure data
/// extracted from `StudioDecompositionService` (plan §3).
class StudioControllerOntology {
  StudioControllerOntology._();

  /// All controller slots, in pipeline order (the last one is the final
  /// generator). The decomposition engine builds one agent per spec.
  static const List<StudioControllerSpec> specs = <StudioControllerSpec>[
    StudioControllerSpec(
      id: 'continuity',
      name: 'Continuity Controller',
      purpose:
          'Track source-of-truth facts, recent chat state, unresolved threads, who knows what, and contradictions to avoid.',
      outputContract:
          'At chat time, output a compact continuity brief only: facts, constraints, risks, and next-turn continuity notes. No scene prose.',
      laneOwns:
          'established facts, who-knows-what, unresolved threads, physical-object/state continuity, and contradictions to avoid.',
      laneSkip:
          'prose style, pacing, length, dialogue cadence, repetition/anti-loop bans, NPC/world activity, and user-agency rules.',
      refreshPolicy: 'turn',
      invalidationSignals: ['last_user_message_changed', 'memory_changed'],
      temperature: 0.3,
      maxTokens: 1600,
      timeoutMs: 60000,
    ),
    StudioControllerSpec(
      id: 'agency',
      name: 'Agency & Character Controller',
      purpose:
          'Enforce user sovereignty, character autonomy, character psychology, subjective knowledge, and believable behavior.',
      outputContract:
          'At chat time, output actionable constraints for user agency and character behavior. No scene prose, no drafted actions, no dialogue. You may add an optional "Options" list of 1-3 branchable character-behavior approaches the final writer can pick from (describe the approach only, e.g. "let the character deflect" vs "let a crack of honesty show"); never write ready-made lines or actions.',
      laneOwns:
          'user sovereignty (never write the user) and character autonomy/psychology: what a character can plausibly know, feel, and do this turn.',
      laneSkip:
          'plain factual continuity, prose style/length, dialogue formatting, repetition bans, and ambient world/NPC texture.',
      refreshPolicy: 'turn',
      invalidationSignals: [
        'active_cast_changed',
        'relationship_state_changed',
      ],
      temperature: 0.3,
      maxTokens: 1400,
      timeoutMs: 60000,
    ),
    StudioControllerSpec(
      id: 'dialogue',
      name: 'Dialogue Controller',
      purpose:
          'Control dialogue cadence, speech texture, monologue segmentation, interaction balance, and when silence is appropriate. Your job is dialogue RATIO and TEXTURE — you do NOT decide beat type or paragraph budget (that is the Narrative Controller\'s lane). Provide a dialogue ratio that is compatible with the scene\'s actual beat: action beats can still be dialogue-heavy (characters talk while moving/riding/fighting); a high dialogue ratio does NOT downgrade an action beat into a short conversational one.',
      outputContract:
          'At chat time, output dialogue guidance only: who may plausibly speak, desired dialogue ratio (low / medium / high — relative to the beat, not absolute), speech constraints, and silence constraints. State the ratio as a proportion of the response that should be spoken lines vs physical action/narration, compatible with whatever beat type the Narrative Controller chose. No drafted lines. You may add an optional "Options" list of 1-3 branchable dialogue approaches the final writer can pick from (describe the approach only, e.g. "answer with silence and a gesture" vs "give one clipped deflecting line"); never write the actual dialogue.',
      laneOwns:
          'dialogue cadence only: who may plausibly speak, speech ratio (low/medium/high relative to the beat), silence, and quoting/formatting of speech. A high dialogue ratio does NOT downgrade an action beat into a short conversational one — action beats can be dialogue-heavy.',
      laneSkip:
          'factual continuity, character knowledge/psychology, prose length/pacing, repetition bans, and world/NPC activity.',
      refreshPolicy: 'turn',
      invalidationSignals: [
        'last_user_message_changed',
        'active_speaker_changed',
      ],
      temperature: 0.3,
      maxTokens: 1200,
      timeoutMs: 60000,
    ),
    StudioControllerSpec(
      id: 'guard',
      name: 'Anti-Loop & Prose Guard',
      purpose:
          'Enforce anti-loop, anti-echo, banlists, anti-cliche, anti-slop, no-tells, and stable prose quality rules.',
      outputContract:
          'At chat time, output a compact guard checklist and forbidden items for this turn. No rewritten scene prose.',
      laneOwns:
          'anti-repetition only: forbidden openings/phrases vs the last replies, banned cliches/slop words, and safe structural variation this turn. Structural variation must never force {{user}} movement, decisions, reactions, silence, or other user-controlled progression.',
      laneSkip:
          'plot facts, character psychology, agency, pacing targets, dialogue content, and world/NPC texture.',
      refreshPolicy: 'turn',
      invalidationSignals: [
        'last_3_replies_changed',
        'last_user_message_changed',
      ],
      temperature: 0.2,
      maxTokens: 1400,
      timeoutMs: 60000,
    ),
    StudioControllerSpec(
      id: 'world',
      name: 'World / NPC Controller',
      purpose:
          'Control living-world texture, NPC ecology, offscreen pressure, public-space activity, and background consequences without stealing focus.',
      outputContract:
          'At chat time, output world/NPC guidance only: active NPCs, off-focus thread, environmental pressure, and what not to add. No prose. You may add an optional "Options" list of 1-3 branchable world-texture approaches the final writer can pick from (describe the approach only, e.g. "let an offscreen sound intrude" vs "keep the world still and pressureless"); never write ready-made prose.',
      laneOwns:
          'living-world texture only: active NPCs, off-screen pressure, environmental/ambient activity, and what world detail NOT to add.',
      laneSkip:
          'the two leads\' psychology, factual continuity, prose style/length, dialogue formatting, and repetition bans.',
      refreshPolicy: 'turn',
      invalidationSignals: [
        'scene_changed',
        'location_changed',
        'active_cast_changed',
      ],
      temperature: 0.3,
      maxTokens: 1200,
      timeoutMs: 60000,
    ),
    StudioControllerSpec(
      id: 'meta',
      name: 'Meta-Weaver / OOC Policy',
      purpose:
          'Meta-weaver / OOC interface controller. Runs EVERY turn when the preset has a meta/OOC block assigned. Counts assistant messages in the history it sees, applies the period rule from the assigned meta block (e.g. "Every 4 assistant responses"), and decides whether the meta-persona should emit an OOC note this turn, respond to an explicit OOC address, or stay silent. The meta-persona\'s name, voice, length, and format are all defined by the user\'s preset block — the controller does NOT hardcode any persona.',
      outputContract:
          'At chat time, output a compact meta brief ONLY. Decide one of: '
          '`meta_ooc: due | topic: <X>` (user addressed the meta-persona OOC), '
          '`meta_periodic_note: due | last_note: <N turns ago> | voice: <from block> | length: <from block> | format: <from block>` (the Nth assistant turn fired the period rule — relay the voice/length/format/wrapper from the assigned meta block so the Main Responder writes in the user\'s chosen style), '
          'or `meta: silent` (neither condition met). Never write in-scene prose, never write the actual OOC reply — that is the Main Responder\'s job, guided by your brief.',
      laneOwns: 'only this controller\'s configured specialty.',
      laneSkip: 'concerns that belong to the other Studio controllers.',
      refreshPolicy: 'turn',
      invalidationSignals: [
        'last_user_message_changed',
        'assistant_turn_count_changed',
      ],
      temperature: 0.2,
      maxTokens: 1200,
      timeoutMs: 60000,
    ),
    StudioControllerSpec(
      id: 'beauty',
      name: 'Beauty Shard',
      purpose:
          'Track reusable visual styling state only: HTML/CSS palette, background, text/font colors, speaker colors, typography, gradients, and art-style labels. Skip concrete HTML widgets, trackers, infoblocks, and image-generation instructions.',
      outputContract:
          'At chat time, output a compact beauty-state brief only: current reusable style variables, constraints for preserving/updating them, and items to avoid. Do NOT write scene prose. Do NOT handle concrete UI artifacts (phone screens, taxi menus, terminals), trackers, infoblocks, topbars, or image-gen blocks.',
      laneOwns:
          'reusable presentation/style state only: HTML/CSS palette, background and text colors, font family, speaker/thought colors, gradients, typography, glow/mark/highlight styles, and art-style labels that should remain consistent across turns.',
      laneSkip:
          'concrete HTML widgets/windows (phone screens, taxi menus, terminals, HUDs, cards, maps, buttons), trackers, stats panels, infoblocks, topbar/infoboard instructions, image-generation prompts, plot facts, character psychology, and scene prose.',
      refreshPolicy: 'turn',
      invalidationSignals: ['last_user_message_changed', 'style_state_changed'],
      temperature: 0.2,
      maxTokens: 1200,
      timeoutMs: 60000,
    ),
    StudioControllerSpec(
      id: 'final',
      name: 'Main Responder',
      purpose:
          'Write the final visible RP response using the full prompt and the prior controller briefs.',
      outputContract:
          'At chat time, output only the final visible RP response. Obey all controller briefs and final formatting/content constraints.',
      laneOwns: 'the final response prose — all scene writing, dialogue, narration, and action.',
      laneSkip: 'analysis, tracking, constraint checking — those belong to the pre-generation agents.',
      refreshPolicy: 'turn',
      invalidationSignals: ['last_user_message_changed'],
      temperature: 0.8,
      maxTokens: 8000,
      timeoutMs: 90000,
      isFinal: true,
      lockedOn: true,
    ),
  ];

  /// Build the default fixed Studio controller agents for a session.
  ///
  /// Kept here so Studio creation, rebuild, and legacy empty-config recovery
  /// all use the same agent set.
  static List<StudioAgent> buildDefaultAgents({
    required String sessionId,
    required int now,
  }) {
    final agents = <StudioAgent>[];
    for (var i = 0; i < specs.length; i++) {
      final spec = specs[i];
      agents.add(
        StudioAgent(
          id: 'agent_${sessionId}_${spec.id}_$now',
          name: spec.name,
          role: 'system',
          order: i,
          enabled: spec.id != 'meta',
          temperature: spec.temperature,
          maxTokens: spec.maxTokens,
          timeoutMs: spec.timeoutMs,
          refreshPolicy: spec.refreshPolicy,
          invalidationSignals: spec.invalidationSignals,
          phase: spec.phase,
          contextSize: spec.contextSize > 0 ? spec.contextSize : 5,
          specId: spec.id,
        ),
      );
    }
    return agents;
  }

  static StudioControllerSpec byId(String specId) {
    return specs.firstWhere(
      (s) => s.id == specId,
      orElse: () => specs[specs.length - 1],
    );
  }

  /// Map an existing agent back to its controller spec. Prefers the agent's
  /// [StudioAgent.specId]; falls back to the legacy name/id substring match
  /// + order-based heuristic (migration — will be removed after backfill).
  static StudioControllerSpec specForAgent(StudioAgent agent) {
    if (agent.specId.isNotEmpty) {
      return byId(agent.specId);
    }
    final text = '${agent.id}\n${agent.name}'.toLowerCase();
    return specs.firstWhere(
      (spec) =>
          text.contains(spec.id) || text.contains(spec.name.toLowerCase()),
      orElse: () => agent.order >= specs.length - 1
          ? specs.last
          : specs[agent.order.clamp(0, specs.length - 1)],
    );
  }
}

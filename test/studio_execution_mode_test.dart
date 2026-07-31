import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/studio_activation_gate.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';

void main() {
  final staleAgents = <StudioAgent>[
    const StudioAgent(
      id: 'agent_s_continuity',
      controllerId: 'continuity',
      name: 'Continuity Controller',
    ),
    const StudioAgent(
      id: 'agent_s_agency',
      controllerId: 'agency',
      name: 'Agency & Character Controller',
    ),
    const StudioAgent(
      id: 'agent_s_dialogue',
      controllerId: 'dialogue',
      name: 'Dialogue Controller',
    ),
    const StudioAgent(
      id: 'agent_s_guard',
      controllerId: 'guard',
      name: 'Anti-Loop & Prose Guard',
    ),
    const StudioAgent(
      id: 'agent_s_world',
      controllerId: 'world',
      name: 'World / NPC Controller',
    ),
    const StudioAgent(
      id: 'agent_s_meta',
      controllerId: 'meta',
      name: 'Meta-Weaver / OOC Policy',
    ),
    const StudioAgent(
      id: 'agent_s_final',
      controllerId: 'final',
      name: 'Main Responder',
    ),
  ];

  test('direct mode blocks every stale pregen controller except final', () {
    final gated = StudioActivationGate.applyExecutionMode(
      staleAgents,
      StudioExecutionMode.direct,
    );

    expect(gated.where((agent) => agent.enabled).map((agent) => agent.name), [
      'Main Responder',
    ]);
  });

  test('assisted permits continuity and final', () {
    final gated = StudioActivationGate.applyExecutionMode(
      staleAgents,
      StudioExecutionMode.assisted,
    );

    expect(gated.where((agent) => agent.enabled).map((agent) => agent.name), [
      'Continuity Controller',
      'Main Responder',
    ]);
  });

  test('topology reports controllers that a mode cannot enable', () {
    expect(
      StudioActivationGate.isControllerAllowed(
        'agency',
        StudioExecutionMode.direct,
      ),
      isFalse,
    );
    expect(
      StudioActivationGate.isControllerAllowed(
        'agency',
        StudioExecutionMode.assisted,
      ),
      isFalse,
    );
    expect(
      StudioActivationGate.isControllerAllowed(
        'continuity',
        StudioExecutionMode.assisted,
      ),
      isTrue,
    );
    expect(
      StudioActivationGate.isControllerAllowed(
        'dialogue',
        StudioExecutionMode.assisted,
      ),
      isFalse,
    );
  });
}

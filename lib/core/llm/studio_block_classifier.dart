import '../models/preset.dart';

/// Recognizes chain-of-thought / reasoning templates among a plain preset's
/// blocks, so the Studio bucketizer can drop them from the static context the
/// agents see — the multi-agent pipeline externalizes reasoning, so a CoT
/// scaffold in the prompt is duplicated work.
///
/// What is left of the block classifier the decomposition service used to
/// need. Its keyword bucketing (`bucketForBlock`) and broadcast detection
/// (`isBroadcastBlock`) went with the service: agents are pinned to their
/// specs now (§4) and blocks are addressed explicitly (§5), so nothing routes
/// a block by guessing from its name.
class StudioBlockClassifier {
  StudioBlockClassifier._();

  /// True if a block is a chain-of-thought / reasoning / thinking template.
  /// Such blocks describe HOW to reason internally; the multi-agent pipeline
  /// already externalizes reasoning, so they are dropped before routing rather
  /// than assigned to an agent.
  ///
  /// This is the deterministic fallback used when the LLM router is
  /// unavailable. It is intentionally conservative: a block that merely
  /// *mentions* a `<think>` block is NOT reasoning. When in doubt, keep the
  /// block (return false) so the router/keyword bucketing can still place it.
  static bool isReasoningBlock(PresetBlock block) {
    final name = block.name.toLowerCase();
    final id = block.id.toLowerCase();

    // Strong name/id signals (cheap, high-precision).
    const nameNeedles = [
      'cot',
      'chain of thought',
      'chain-of-thought',
      'reasoning',
      'think template',
      'thinking',
      '<think>',
    ];
    for (final needle in nameNeedles) {
      if (name.contains(needle) || id.contains(needle)) return true;
    }

    return _contentIsReasoningTemplate(block.content);
  }

  /// Content-based reasoning detection. Distinguishes a block that IS a
  /// reasoning/CoT template from one that merely references `<think>`.
  ///
  /// Two positive signals:
  /// 1. The block is *dominated* by think-tag content — most of the block lives
  ///    inside the reasoning tags (a real CoT scaffold).
  /// 2. The block actively *directs the model to produce* a think block (an
  ///    action verb tied to the tag, e.g. `use`, `plan internally`, `before
  ///    replying`). A passive description (the think block "stays English") is
  ///    excluded.
  static bool _contentIsReasoningTemplate(String content) {
    if (content.isEmpty) return false;
    final lower = content.toLowerCase();
    if (!lower.contains('<think>')) return false;

    // Signal 1: think tags dominate the block.
    final insideThink = RegExp(
      r'<think>([\s\S]*?)</think>',
      caseSensitive: false,
    );
    var insideChars = 0;
    for (final m in insideThink.allMatches(content)) {
      insideChars += (m.group(1) ?? '').length;
    }
    final ratio = insideChars / content.length;
    if (ratio >= _reasoningDominanceRatio) return true;

    // Signal 2: an explicit directive to emit a <think> reasoning block. These
    // patterns require an action verb tied to the tag, so passive mentions
    // ("after </think>", "the <think> block remains English") do not match.
    const directivePatterns = [
      r'use\s+<think>',
      r'<think>[^<]*</think>\s*(?:for|to)\b',
      r'(?:plan|think|reason)\s+(?:internally|step[- ]by[- ]step)[^.]*<think>',
      r'(?:before|prior to)\s+(?:replying|responding|answering)[^.]*<think>',
      r'wrap\s+(?:your\s+)?(?:reasoning|planning|thinking)\s+in\s+<think>',
    ];
    for (final p in directivePatterns) {
      if (RegExp(p, caseSensitive: false).hasMatch(lower)) return true;
    }
    return false;
  }

  /// Fraction of a block that must live inside `<think>...</think>` for the
  /// block to count as a reasoning template via signal 1.
  static const double _reasoningDominanceRatio = 0.4;
}

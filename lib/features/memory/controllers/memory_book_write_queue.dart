import '../../../core/models/memory_book.dart';

typedef MemoryBookMutation = MemoryBook? Function(MemoryBook current);

/// Serializes MemoryBook persistence while allowing generation to apply a
/// narrow mutation to the freshest in-memory book.
///
/// Ordinary CRUD calls use [saveLatest], which deliberately reads the book
/// only after earlier writes finish. Draft generation uses [mutate]: two
/// completions therefore compose instead of saving competing full snapshots.
class MemoryBookWriteQueue {
  final MemoryBook? Function() readLatest;
  final void Function(MemoryBook book) publish;
  final Future<void> Function(MemoryBook book) persist;

  Future<void> _tail = Future<void>.value();

  MemoryBookWriteQueue({
    required this.readLatest,
    required this.publish,
    required this.persist,
  });

  Future<void> saveLatest() => _enqueue(() async {
    final latest = readLatest();
    if (latest != null) await persist(latest);
  });

  /// Applies [mutation] inside the serialized operation and persists it.
  ///
  /// After persistence, the same narrow mutation is re-applied to the latest
  /// in-memory book before publication. This preserves synchronous CRUD edits
  /// made while persistence was awaiting I/O. Returning `null` from [mutation]
  /// means the target no longer exists or the operation lost ownership.
  Future<bool> mutate(MemoryBookMutation mutation) {
    var applied = false;
    return _enqueue(() async {
      final latest = readLatest();
      if (latest == null) return;
      final candidate = mutation(latest);
      if (candidate == null) return;

      await persist(candidate);

      final afterPersistence = readLatest();
      if (afterPersistence == null) return;
      final merged = mutation(afterPersistence);
      if (merged == null) return;
      publish(merged);
      applied = true;
    }).then((_) => applied);
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final previous = _tail;
    final next = () async {
      try {
        await previous;
      } catch (_) {
        // One failed write must not poison subsequent queued operations.
      }
      await operation();
    }();
    _tail = next.then<void>((_) {}, onError: (_, _) {});
    return next;
  }
}

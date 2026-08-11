import 'package:drift/native.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/embedding_repo.dart';
import 'package:glaze_flutter/core/llm/embedding_service.dart';
import 'package:glaze_flutter/core/llm/lorebook_embedding_service.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';

class _FakeEmbeddingService extends EmbeddingService {
  final List<String> requestedTexts = [];

  @override
  Future<List<EmbeddingChunk>> getEmbeddingsWithChunks(
    List<String> texts,
    EmbeddingConfig config, {
    CancelToken? cancelToken,
  }) async {
    requestedTexts.addAll(texts);
    return [
      for (final text in texts)
        EmbeddingChunk(text: text, vector: const [1, 0]),
    ];
  }
}

void main() {
  test('keys embedding target indexes and fingerprints entry keys', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = EmbeddingRepo(db);
    final embeddingService = _FakeEmbeddingService();
    final service = LorebookEmbeddingService(repo, embeddingService);
    const entry = LorebookEntry(
      id: 'entry',
      keys: ['alpha', 'beta'],
      content: 'content must not be embedded',
      vectorSearch: true,
    );
    const config = EmbeddingConfig(
      endpoint: 'http://localhost/v1',
      model: 'test',
    );

    final result = await service.indexLorebookEntries(
      'book',
      const [entry],
      config,
      embeddingTarget: 'keys',
    );

    expect(result.indexed, 1);
    expect(embeddingService.requestedTexts, ['alpha, beta']);
    final row = await repo.getByEntryId('book_entry');
    expect(
      row?.textHash,
      computeHash(
        LorebookEmbeddingService.buildEmbeddingFingerprint(
          entry,
          'alpha, beta',
        ),
      ),
    );
  });
}

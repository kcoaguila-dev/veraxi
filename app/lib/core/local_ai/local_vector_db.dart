import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'local_document_chunk.dart';
import '../../objectbox.g.dart';

class LocalVectorDb {
  late final Store store;
  late final Box<LocalDocumentChunk> chunkBox;

  Future<void> init() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final storePath = p.join(docsDir.path, 'objectbox-local-rag');

    store = await openStore(directory: storePath);
    chunkBox = store.box<LocalDocumentChunk>();
  }

  void insertChunk(String text, List<double> embedding, {String? metadata}) {
    final chunk = LocalDocumentChunk(
      text: text,
      embedding: embedding,
      metadata: metadata,
    );
    chunkBox.put(chunk);
  }

  List<LocalDocumentChunk> searchSimilar(List<double> queryVector,
      {int maxResults = 3}) {
    final query = chunkBox
        .query(LocalDocumentChunk_.embedding
            .nearestNeighborsF32(queryVector, maxResults))
        .build();

    final results = query.find();
    query.close();
    return results;
  }

  void close() {
    store.close();
  }
}

import 'package:objectbox/objectbox.dart';

@Entity()
class LocalDocumentChunk {
  @Id()
  int id = 0;

  String text;

  @HnswIndex(dimensions: 384) // e.g. all-MiniLM-L6-v2 uses 384 dims
  @Property(type: PropertyType.floatVector)
  List<double>? embedding;

  String? metadata;

  LocalDocumentChunk({
    required this.text,
    this.embedding,
    this.metadata,
  });
}

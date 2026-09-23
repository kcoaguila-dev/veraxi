import os
import backend.ingestion.__main__ as m
print("File:", m.__file__)
print("Dirname1:", os.path.dirname(m.__file__))
print("Dirname2:", os.path.dirname(os.path.dirname(m.__file__)))
path = os.path.join(os.path.dirname(os.path.dirname(m.__file__)), "tests", "data", "graphrag_test_corpus.txt")
print("Path:", path)
print("Exists:", os.path.exists(path))

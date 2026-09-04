import json
import os
import random

from datasets import load_dataset

CORPUS_PATH = os.path.join(os.path.dirname(__file__), "..", "tests", "data", "graphrag_test_corpus.txt")
DATASET_PATH = os.path.join(os.path.dirname(__file__), "dataset.json")

import argparse


def generate_multihop():
    print("Loading MultiHop-RAG dataset from Hugging Face...")
    dataset = load_dataset("yixuantt/MultiHopRAG", "MultiHopRAG", split="train", streaming=True)
    samples = list(dataset.take(10))
    
    corpus_paragraphs = []
    evaluation_dataset = []
    
    for item in samples:
        question = item['query']
        answer = item['answer']
        evidence_list = item.get('evidence_list', [])
        
        for evidence in evidence_list:
            title = evidence.get('title', 'Unknown Title')
            fact = evidence.get('fact', '')
            if fact:
                full_paragraph = f"{title}: {fact}"
                if full_paragraph not in corpus_paragraphs:
                    corpus_paragraphs.append(full_paragraph)
            
        evaluation_dataset.append({
            "query": question,
            "expected_answer": answer,
        })
        
    return corpus_paragraphs, evaluation_dataset

def generate_graphrag_bench():
    print("Loading GraphRAG-Bench (Medical) dataset from Hugging Face...")
    dataset = load_dataset("GraphRAG-Bench/GraphRAG-Bench", "medical", split="train", streaming=True)
    samples = list(dataset.take(10))
    
    corpus_paragraphs = []
    evaluation_dataset = []
    
    for item in samples:
        question = item['question']
        answer = item['answer']
        
        evidence = item.get('evidence', [])
        if isinstance(evidence, str):
            evidence = [evidence]
            
        for e in evidence:
            if e and e not in corpus_paragraphs:
                corpus_paragraphs.append(e)
            
        evaluation_dataset.append({
            "query": question,
            "expected_answer": answer,
        })
        
    return corpus_paragraphs, evaluation_dataset

def generate():
    parser = argparse.ArgumentParser(description="Generate RAG evaluation benchmarks.")
    parser.add_argument("--dataset", type=str, choices=["multihop", "graphrag_bench"], default="multihop", help="Dataset to use for benchmarking.")
    args = parser.parse_args()
    
    if args.dataset == "multihop":
        corpus_paragraphs, evaluation_dataset = generate_multihop()
    elif args.dataset == "graphrag_bench":
        corpus_paragraphs, evaluation_dataset = generate_graphrag_bench()
    
    random.seed(42)
    random.shuffle(corpus_paragraphs)
    
    corpus_text = "\n\n".join(corpus_paragraphs)
    
    os.makedirs(os.path.dirname(CORPUS_PATH), exist_ok=True)
    with open(CORPUS_PATH, "w") as f:
        f.write(corpus_text)
        
    print(f"Generated test corpus at {CORPUS_PATH} with {len(corpus_paragraphs)} unique evidence paragraphs.")
    
    os.makedirs(os.path.dirname(DATASET_PATH), exist_ok=True)
    with open(DATASET_PATH, "w") as f:
        json.dump(evaluation_dataset, f, indent=4)
        
    print(f"Generated golden dataset at {DATASET_PATH} with {len(evaluation_dataset)} {args.dataset} benchmark questions.")

if __name__ == "__main__":
    generate()

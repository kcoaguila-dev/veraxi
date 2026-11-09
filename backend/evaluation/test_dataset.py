def main() -> None:
	from datasets import load_dataset

	dataset = load_dataset("google/frames-benchmark", split="test", streaming=True)
	sample = next(iter(dataset))
	print("KEYS:", sample.keys())
	print("Query:", sample.get("Prompt", sample.get("query", ""))[:100])
	print("Answer:", sample.get("Answer", sample.get("answer", ""))[:100])


if __name__ == "__main__":
	main()

# /// script
# requires-python = ">=3.10"
# dependencies = ["fastembed>=0.7,<1"]
# ///
"""Embed packed passages and statements with intfloat/multilingual-e5-small.

fastembed runs the ONNX model without PyTorch. The model is MIT licensed and its ONNX file is
about 470 MB (the quantized file about 118 MB); it lives in the Hugging Face cache, the uv
environment in uv's cache. Nothing is installed in the skill repository.

Usage:
  uv run --script embed_packs.py --workdir <workdir> [--model intfloat/multilingual-e5-small]
"""

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import packs  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--model", default="intfloat/multilingual-e5-small")
    parser.add_argument("--batch-size", type=int, default=32)
    args = parser.parse_args()
    work = Path(args.workdir).resolve()

    from fastembed import TextEmbedding

    pages = packs.read_pages(work)
    passages = []
    for page in pages:
        for row in packs.split_passages(page["body"]):
            passages.append({**row, "page": page["number"], "url": page["url"]})
    statements = [json.loads(line) for line in
                  (work / "statements.jsonl").read_text(encoding="utf-8").splitlines()
                  if line.strip()]

    model = TextEmbedding(model_name=args.model)
    passage_texts = ["passage: " + (p.get("heading", "") + " " + p["text"]).strip()
                     for p in passages]
    statement_texts = ["query: " + (s.get("self_contained") or s.get("text", ""))
                       for s in statements]
    passage_vectors = list(model.embed(passage_texts, batch_size=args.batch_size))
    statement_vectors = list(model.embed(statement_texts, batch_size=args.batch_size))

    out = {"model": args.model, "licence": "MIT",
           "dim": len(passage_vectors[0]) if passage_vectors else 0,
           "passages": {packs.passage_key(p): [float(x) for x in vec]
                        for p, vec in zip(passages, passage_vectors)},
           "statements": {s["sid"]: [float(x) for x in vec]
                          for s, vec in zip(statements, statement_vectors)}}
    target = work / "packs" / "embeddings.json"
    target.parent.mkdir(exist_ok=True)
    target.write_text(json.dumps(out), encoding="utf-8")
    print("embed_packs: %d passages, %d statements, %d dimensions -> %s"
          % (len(passages), len(statements), out["dim"], target))
    return 0


if __name__ == "__main__":
    sys.exit(main())

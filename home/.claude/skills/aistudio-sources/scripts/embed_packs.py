# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "onnxruntime>=1.17,<2",
#   "tokenizers>=0.15,<1",
#   "huggingface_hub>=0.23,<1",
#   "numpy>=1.26,<3",
# ]
# ///
"""Embed packed passages and statements with intfloat/multilingual-e5-small.

The model runs through ONNX Runtime, without PyTorch. The ONNX file is about 470 MB and lives in
the Hugging Face cache; the Python environment lives in uv's cache. Nothing is installed in the
skill repository. fastembed does not list this model in its TextEmbedding registry, so the script
feeds the tokenizer and the ONNX session directly and applies E5's mean pooling.

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


def load_model(model_name):
    import numpy as np
    import onnxruntime as ort
    from huggingface_hub import hf_hub_download
    from tokenizers import Tokenizer

    model_path = hf_hub_download(model_name, "onnx/model.onnx")
    tokenizer_path = hf_hub_download(model_name, "onnx/tokenizer.json")
    tokenizer = Tokenizer.from_file(tokenizer_path)
    tokenizer.enable_truncation(max_length=512)
    tokenizer.enable_padding(pad_id=0, pad_token="<pad>")
    session = ort.InferenceSession(model_path, providers=["CPUExecutionProvider"])
    return tokenizer, session, np


def embed(texts, tokenizer, session, np, batch_size):
    vectors = []
    input_names = {i.name for i in session.get_inputs()}
    for start in range(0, len(texts), batch_size):
        batch = tokenizer.encode_batch(texts[start:start + batch_size])
        ids = np.array([e.ids for e in batch], dtype=np.int64)
        mask = np.array([e.attention_mask for e in batch], dtype=np.int64)
        feed = {"input_ids": ids, "attention_mask": mask}
        if "token_type_ids" in input_names:
            feed["token_type_ids"] = np.zeros_like(ids)
        hidden = session.run(None, feed)[0]
        mask_f = mask[..., None].astype(hidden.dtype)
        pooled = (hidden * mask_f).sum(axis=1) / np.clip(mask_f.sum(axis=1), 1, None)
        pooled = pooled / np.clip(np.linalg.norm(pooled, axis=1, keepdims=True), 1e-12, None)
        vectors.extend(pooled.tolist())
    return vectors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--model", default="intfloat/multilingual-e5-small")
    parser.add_argument("--batch-size", type=int, default=32)
    args = parser.parse_args()
    work = Path(args.workdir).resolve()

    try:
        tokenizer, session, np = load_model(args.model)
    except Exception as exc:  # network, missing file, unsupported runtime
        print("embed_packs: model not available (%s)" % exc)
        print("embed_packs: continue with the two-signal pack; no embeddings written")
        return 2

    pages = packs.read_pages(work)
    passages = []
    for page in pages:
        for row in packs.split_passages(page["body"]):
            passages.append({**row, "page": page["number"], "url": page["url"]})
    statements = [json.loads(line) for line in
                  (work / "statements.jsonl").read_text(encoding="utf-8").splitlines()
                  if line.strip()]

    passage_texts = ["passage: " + (p.get("heading", "") + " " + p["text"]).strip()
                     for p in passages]
    statement_texts = ["query: " + (s.get("self_contained") or s.get("text", ""))
                       for s in statements]
    passage_vectors = embed(passage_texts, tokenizer, session, np, args.batch_size)
    statement_vectors = embed(statement_texts, tokenizer, session, np, args.batch_size)

    out = {"model": args.model, "licence": "MIT",
           "dim": len(passage_vectors[0]) if passage_vectors else 0,
           "passages": {packs.passage_key(p): vec
                        for p, vec in zip(passages, passage_vectors)},
           "statements": {s["sid"]: vec
                          for s, vec in zip(statements, statement_vectors)}}
    target = work / "packs" / "embeddings.json"
    target.parent.mkdir(exist_ok=True)
    target.write_text(json.dumps(out), encoding="utf-8")
    print("embed_packs: %d passages, %d statements, %d dimensions -> %s"
          % (len(passages), len(statements), out["dim"], target))
    return 0


if __name__ == "__main__":
    sys.exit(main())

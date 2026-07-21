#!/usr/bin/env python3
"""Regenerate xupin's word-level bigram model from an open Chinese corpus.

The static dictionary (tools/build-dict.py) defines *which* words a pinyin string can
map to; this model defines *which of them is more likely given the preceding word* — the
statistical fuel behind context-aware ranking (issue #6, see repo-root CONTEXT.md's
"训练语料" vs "词典数据" distinction).

Pipeline:
  1. Download the Leipzig Corpora Collection Chinese news sentences (CC BY 4.0), pinned to
     one release file below, and extract its `*-sentences.txt`.
  2. Word-segment each sentence with jieba (build-time-only tool, MIT).
  3. Count adjacent (prevWord, word) pairs, keeping only pairs where BOTH tokens are in the
     static dictionary's vocabulary (so every modelled word is one the IME can actually
     surface as a candidate) and are pure CJK (drops digits/latin/punctuation tokens).
  4. Prune to bound the shipped asset (see MIN_COUNT / TOP_K below and THIRD_PARTY_NOTICES.md).

Writes:
  - entry/src/main/resources/rawfile/bigram/bigrams.dict.tsv  (runtime bigram model asset)

Format: `prevWord\tword\tcount` per line, grouped by prevWord, count-descending within a
group — mirrors words.dict.tsv so BigramModel.parse does no runtime sorting.

See ../THIRD_PARTY_NOTICES.md for the corpus/tool licenses and why these prune sizes.
Run from the xupin/ directory: `pip install jieba && python3 tools/build-bigram.py`
"""
import io
import os
import sys
import tarfile
import urllib.request
from collections import defaultdict

# Leipzig Corpora Collection, Chinese (zho) news 2020, 100K sentences. CC BY 4.0.
# Pinned by exact release filename; Leipzig release files are immutable once published.
CORPUS_NAME = "zho_news_2020_100K"
CORPUS_URL = f"https://downloads.wortschatz-leipzig.de/corpora/{CORPUS_NAME}.tar.gz"

MIN_COUNT = 5   # drop bigrams observed fewer times — noise floor and the main size lever
TOP_K = 40      # keep at most this many successors per preceding word

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
XUPIN_ROOT = os.path.dirname(SCRIPT_DIR)
DICT_TSV = os.path.join(XUPIN_ROOT, "entry/src/main/resources/rawfile/dict/words.dict.tsv")
BIGRAM_OUT = os.path.join(XUPIN_ROOT, "entry/src/main/resources/rawfile/bigram/bigrams.dict.tsv")


def is_cjk_word(token):
    if not token:
        return False
    for ch in token:
        if not ("一" <= ch <= "鿿"):
            return False
    return True


def load_vocab():
    vocab = set()
    with open(DICT_TSV, "r", encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) == 3:
                vocab.add(parts[1])
    print(f"dictionary vocab: {len(vocab)} words", file=sys.stderr)
    return vocab


def fetch_sentences():
    print(f"fetching {CORPUS_URL}", file=sys.stderr)
    with urllib.request.urlopen(CORPUS_URL, timeout=120) as resp:
        raw = resp.read()
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as tar:
        member = next(m for m in tar.getmembers() if m.name.endswith("-sentences.txt"))
        text = tar.extractfile(member).read().decode("utf-8")
    # Leipzig sentence files are `id<TAB>sentence` per line.
    sentences = []
    for line in text.split("\n"):
        tab = line.find("\t")
        if tab != -1:
            sentences.append(line[tab + 1:])
    print(f"corpus sentences: {len(sentences)}", file=sys.stderr)
    return sentences


def main():
    import jieba

    vocab = load_vocab()
    sentences = fetch_sentences()

    counts = defaultdict(lambda: defaultdict(int))
    for i, sentence in enumerate(sentences):
        # Iterate over ORIGINAL adjacent token pairs and qualify each pair in place. Filtering the
        # token stream *before* pairing would delete a punctuation / digit / Latin / out-of-vocab
        # token sitting between two words and fuse those words into a bigram that never occurred
        # ("A , B" -> counts A->B). Requiring both members of an adjacent pair to qualify instead
        # lets any non-qualifying token break adjacency — which also matches inference, where a
        # committed delimiter resets the bigram context (see BigramScorer).
        tokens = list(jieba.cut(sentence))
        for a, b in zip(tokens, tokens[1:]):
            if is_cjk_word(a) and a in vocab and is_cjk_word(b) and b in vocab:
                counts[a][b] += 1
        if (i + 1) % 20000 == 0:
            print(f"  segmented {i + 1}/{len(sentences)} sentences", file=sys.stderr)

    os.makedirs(os.path.dirname(BIGRAM_OUT), exist_ok=True)
    total = 0
    with open(BIGRAM_OUT, "w", encoding="utf-8") as out:
        for prev in sorted(counts.keys()):
            succ = [(w, c) for w, c in counts[prev].items() if c >= MIN_COUNT]
            succ.sort(key=lambda wc: -wc[1])
            for word, count in succ[:TOP_K]:
                out.write(f"{prev}\t{word}\t{count}\n")
                total += 1
    print(f"wrote {total} bigram entries to {BIGRAM_OUT}", file=sys.stderr)


if __name__ == "__main__":
    main()

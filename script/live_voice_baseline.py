#!/usr/bin/env python3
"""Read-only voice/caption audit. Never infer identity labels from clustering.

Accepts a library root or a directory containing SQLite snapshots. The output
contains counts and similarities, never transcripts, audio or embeddings.
"""
import argparse
import array
import collections
import hashlib
import json
import math
from pathlib import Path
import sqlite3


def vector(blob):
    return list(array.array("f", blob)) if blob else None


def similarity(a, b):
    if not a or not b or len(a) != len(b):
        return -1.0
    return sum(x * y for x, y in zip(a, b))


def centroid(vectors):
    if not vectors:
        return None
    total = [sum(x) for x in zip(*vectors)]
    norm = math.sqrt(sum(x * x for x in total))
    return [x / norm for x in total] if norm else None


def audit(directory):
    sync = directory / "Sync" if (directory / "Sync").is_dir() else directory
    db = sqlite3.connect(f"file:{sync / 'voice-campplus-v1.sqlite'}?mode=ro", uri=True)
    captions = sqlite3.connect(f"file:{sync / 'recent-captions.sqlite'}?mode=ro", uri=True)
    db.execute("BEGIN")
    captions.execute("BEGIN")
    samples = [dict(id=i, group=g, voice=vector(v), seconds=n / 2000 if n else None)
               for i, g, v, n in db.execute("""
        SELECT o.turn,t.speaker,t.voice,length(a.packets) FROM owner_samples o
        JOIN turns t ON t.id=o.turn LEFT JOIN owner_sample_audio a ON a.evidence=o.turn
        ORDER BY o.rowid""")]
    groups = {g: (vector(v), name is not None or bool(rejected))
              for g, v, name, rejected in db.execute("SELECT id,reference,name,rejected FROM speakers")}
    grouped = collections.defaultdict(list)
    individual = []
    for sample in samples:
        group = sample["group"]
        if not group or groups[group][1]:
            individual.append(sample["voice"])
        else:
            grouped[group].append(sample["voice"])
    profiles = {g: centroid(vs) for g, vs in grouped.items()}
    negatives = [vector(b) for b, in db.execute("""
        SELECT t.voice FROM non_owner_samples n JOIN turns t ON t.id=n.evidence
        JOIN utterance_marks m ON m.turn=n.mark WHERE m.mine=0 AND length(t.voice)>0
        UNION ALL SELECT enrolled FROM archive_speakers WHERE name<>'' AND enrolled IS NOT NULL""")]
    pairwise = [[round(similarity(a["voice"], b["voice"]), 6) for b in samples] for a in samples]
    sample_rows = []
    for i, sample in enumerate(samples):
        held_out = centroid([s["voice"] for j, s in enumerate(samples) if j != i])
        sample_rows.append({"key": hashlib.sha256(sample["id"].encode()).hexdigest()[:12],
                            "kind": sample["id"].split(":")[0], "saved_audio_seconds": sample["seconds"],
                            "leave_one_out_consistency": similarity(sample["voice"], held_out),
                            "label_source": "explicit_owner_feedback"})
    latest = captions.execute("SELECT max(time) FROM captions").fetchone()[0] or 0
    buckets = collections.defaultdict(collections.Counter)
    for raw, audio_length in captions.execute("SELECT record,length(audio) FROM captions WHERE time>=?", (latest - 86400,)):
        record = json.loads(raw)
        frames = record.get("replay")
        if not record.get("isFinal") or not frames:
            continue
        seconds = (frames["end"] - frames["start"]) / 16000
        key = "<2" if seconds < 2 else "2-5" if seconds < 5 else "5-10" if seconds < 10 else "10-20" if seconds < 20 else ">=20"
        bucket = buckets[key]
        bucket["captions"] += 1
        bucket["with_audio"] += bool(audio_length)
        turn = None
        for field in ["localVoiceID", "evidenceID"]:
            if record.get(field):
                row = db.execute("SELECT voice,speaker FROM turns WHERE id=?", (record[field],)).fetchone()
                if row and row[0]:
                    turn = row
                    break
        if turn is None:
            bucket["no_stored_embedding"] += 1
            continue
        voice, group = vector(turn[0]), turn[1]
        bucket["with_embedding"] += 1
        candidate_score = max([similarity(voice, s["voice"]) for s in samples]
                              + [similarity(voice, v) for v in profiles.values()] + [-1])
        negative_score = max([similarity(voice, v) for v in negatives] + [-1])
        if candidate_score >= 0.62 and (negative_score < 0.62 or candidate_score >= negative_score + 0.06):
            bucket["candidate_explicit_profile_gate_pass"] += 1
        only_individual = bool(group and groups[group][1])
        score = max([similarity(voice, v) for v in individual]
                    + ([] if only_individual else [similarity(voice, v) for v in profiles.values()]) + [-1])
        competing = (max([similarity(voice, v) for g, (v, _) in groups.items() if g not in profiles] + [-1])
                     if group is None else -1 if group in profiles else similarity(voice, groups[group][0]))
        if score < 0.62:
            bucket["below_owner_threshold"] += 1
        elif score < competing + 0.06:
            bucket["blocked_by_auto_group"] += 1
        else:
            bucket["owner_score_and_group_pass"] += 1
    result = {"scope": "24 hours ending at the latest saved caption in this snapshot",
              "unlabeled_counts_are_not_accuracy": True,
              "candidate_scope": "Decision-layer sensitivity on stored vectors only; not rolling inference, identity accuracy or proof that additional accepted captions are the owner",
              "owner_samples": sample_rows, "owner_pairwise_similarity": pairwise,
              "negative_samples": db.execute("SELECT count(*) FROM non_owner_samples").fetchone()[0],
              "owner_marks_without_enrollment": db.execute("SELECT count(*) FROM utterance_marks WHERE mine=1").fetchone()[0],
              "caption_buckets": {k: dict(v) for k, v in buckets.items()},
              "latest_caption_unix": latest}
    db.close()
    captions.close()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("library", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    if output.is_relative_to(repo):
        parser.error("Output must be outside the repository")
    result = audit(args.library.resolve())
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    output.chmod(0o600)
    print(f"Audited {len(result['owner_samples'])} explicit owner samples; unlabelled counts are not accuracy.")


if __name__ == "__main__":
    main()

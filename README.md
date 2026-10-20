# star-face

StarIntel facial-recognition document plugin. Produces StarIntel documents
solely from facial-recognition results (InsightFace-style JSON) and exposes
actor-to-actor DB search.

- Domain system and actors are defined in Star-Lang (`org.starintel/star-face@1`).
- Targets StarIntel release `0.9.1` (immutable base schema `0.9.0`),
  canonical `lost-rob0t/starintel-gpt-auto-dig@6479c0a9`.
- Private repository; no public deployment. Owned by `starintel-labs`.
- Origin: `git.starintel.actor` (Forgejo). GitHub is fallback only.

## Video pipeline

External engines compute; this domain only turns results into documents.
`scripts/pipeline-video` runs the full flow over a local or URL video
(URLs download via yt-dlp): engine (hash-pinned YuNet/SFace, mirroring
face-intel) emits one InsightFace-style envelope per sampled frame, the
`face-ingest` actor persists StarIntel documents under `db/<dtype>/`, and
`face-search` answers embedding or identity probes.

```sh
export STAR_FACE_YUNET_MODEL=... STAR_FACE_YUNET_SHA256=8f2383e4...
export STAR_FACE_SFACE_MODEL=... STAR_FACE_SFACE_SHA256=0ba9fbfa...
nix run .#star-face-pipeline -- --db ./db --search VIDEO_OR_URL
```

Models are operator-provided (same pins as face-intel CI). Without models,
`--stub` exercises the full engine->ingest->search wiring deterministically;
gate 4 in `tests/run-gates.sh` does exactly that, including durable
redelivery dedupe when `STAR_FACE_CLOCK` is pinned. `fixtures/` carries a
small CC BY-SA clip used by the real-model end-to-end run.


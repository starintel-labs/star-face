#!/usr/bin/env python3
"""External face-recognition engine for the star-face domain.

Emits one JSON line per processed frame; each line is the InsightFace-style
envelope consumed by scripts/ingest-face-results.lisp:

    {"mediaRef": "...", "engine": "...", "faces": [{"bbox": [x,y,w,h],
     "kps": [[x,y],...], "det_score": 0.9, "embedding": [...],
     "detector": "..."}]}

The domain converts these results into StarIntel documents; this engine only
computes. Inference mirrors lost-rob0t/face-intel@7aa3a6e (detection.py,
similarity.py): hash-pinned YuNet detection (score 0.9, nms 0.3, top_k 5000),
SFace alignment, and a 112x112 SFace embedding blob. --stub emits
deterministic synthetic results with no model or OpenCV dependency for
hermetic pipeline tests.
"""

import argparse
import hashlib
import json
import sys
from pathlib import Path

MAX_MODEL_BYTES = 100 * 1024 * 1024


def fail(message):
    print(f"face-engine: {message}", file=sys.stderr)
    raise SystemExit(2)


def model_buffer(path, digest, label):
    import numpy as np

    try:
        data = Path(path).read_bytes()
    except OSError as exc:
        fail(f"cannot read {label} model: {exc}")
    if len(data) > MAX_MODEL_BYTES or hashlib.sha256(data).hexdigest() != digest:
        fail(f"{label} model hash mismatch or size limit exceeded")
    return np.frombuffer(data, dtype=np.uint8)


class StubEngine:
    engine_id = "stub-face-engine:v1"
    detector_id = "stub"

    def faces(self, frame):
        return [
            {
                "bbox": [10.0, 20.0, 110.0, 120.0],
                "kps": [[30.0, 50.0], [90.0, 50.0], [60.0, 80.0], [40.0, 100.0], [80.0, 100.0]],
                "det_score": 0.95,
                "embedding": [0.1, 0.2, 0.3],
                "detector": self.detector_id,
            }
        ]


class YuNetSFaceEngine:
    def __init__(self, args):
        import cv2
        import numpy as np

        yunet = model_buffer(args.yunet_model, args.yunet_sha256, "YuNet")
        sface = model_buffer(args.sface_model, args.sface_sha256, "SFace")
        empty = np.array([], dtype=np.uint8)
        self.detector = cv2.FaceDetectorYN.create(
            "onnx", yunet, empty, (320, 320), args.det_threshold, 0.3, 5000
        )
        self.aligner = cv2.FaceRecognizerSF.create("onnx", sface, empty)
        self.net = cv2.dnn.readNetFromONNX(sface)
        self.net.setPreferableBackend(cv2.dnn.DNN_BACKEND_OPENCV)
        self.net.setPreferableTarget(cv2.dnn.DNN_TARGET_CPU)
        self.cv2, self.np = cv2, np
        self.detector_id = "opencv-yunet:sha256:" + args.yunet_sha256
        self.engine_id = "opencv-yunet-sface:" + args.sface_sha256[:12]
        self.max_faces = args.max_faces

    def faces(self, frame_bgr):
        self.detector.setInputSize((frame_bgr.shape[1], frame_bgr.shape[0]))
        _, rows = self.detector.detect(frame_bgr)
        results = []
        if rows is None:
            return results
        for row in rows[: self.max_faces]:
            if not self.np.isfinite(row).all():
                fail("detector returned invalid coordinates")
            aligned = self.aligner.alignCrop(frame_bgr, row)
            blob = self.cv2.dnn.blobFromImage(aligned, 1.0, (112, 112), (0, 0, 0), True, False)
            self.net.setInput(blob)
            vector = self.net.forward().reshape(-1)
            results.append(
                {
                    "bbox": [float(value) for value in row[:4]],
                    "kps": row[4:14].reshape(5, 2).tolist(),
                    "det_score": float(row[14]),
                    "embedding": [float(value) for value in vector],
                    "detector": self.detector_id,
                }
            )
        return results


def iter_frames(video, stride, stub):
    """Yield (frame_index, bgr_frame); stub mode yields synthetic frames."""
    if stub:
        yield from ((index, None) for index in range(2))
        return
    import cv2

    capture = cv2.VideoCapture(str(video))
    if not capture.isOpened():
        fail(f"cannot open video: {video}")
    try:
        index = 0
        while True:
            if not capture.grab():
                break
            if index % stride == 0:
                ok, frame = capture.retrieve()
                if ok:
                    yield index, frame
            index += 1
    finally:
        capture.release()


def main():
    parser = argparse.ArgumentParser(description="External FR engine for star-face")
    parser.add_argument("input", help="video or image path")
    parser.add_argument("--stub", action="store_true", help="synthetic output, no models")
    parser.add_argument("--frame-stride", type=int, default=30, help="process every Nth frame")
    parser.add_argument("--det-threshold", type=float, default=0.9, help="YuNet score threshold")
    parser.add_argument("--max-faces", type=int, default=32)
    parser.add_argument("--yunet-model")
    parser.add_argument("--yunet-sha256")
    parser.add_argument("--sface-model")
    parser.add_argument("--sface-sha256")
    args = parser.parse_args()

    if args.stub:
        engine = StubEngine()
    else:
        for flag in ("yunet_model", "yunet_sha256", "sface_model", "sface_sha256"):
            if not getattr(args, flag):
                fail(f"--{flag.replace('_', '-')} is required without --stub")
        engine = YuNetSFaceEngine(args)

    source = Path(args.input)
    if not args.stub and not source.is_file():
        fail(f"input not found: {source}")

    for index, frame in iter_frames(source, max(1, args.frame_stride), args.stub):
        record = {
            "mediaRef": f"{source.resolve()}#frame={index}",
            "engine": engine.engine_id,
            "faces": engine.faces(frame),
        }
        print(json.dumps(record), flush=True)


if __name__ == "__main__":
    main()

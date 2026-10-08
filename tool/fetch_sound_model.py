#!/usr/bin/env python3
"""Fetch the pinned public YAMNet model used by on-device Sound Watch."""

from hashlib import sha256
from pathlib import Path
import urllib.request

MODEL_URL = (
    "https://storage.googleapis.com/mediapipe-models/"
    "audio_classifier/yamnet/float32/latest/yamnet.tflite"
)
MODEL_SHA256 = "4d8b4a53282dc83ef04e3e7dbc4fbc98082e34e44ed798e16c3a0cdd4c584faf"
DESTINATION = Path(__file__).resolve().parents[1] / "assets/models/yamnet.tflite"


def main():
    if DESTINATION.is_file():
        if sha256(DESTINATION.read_bytes()).hexdigest() == MODEL_SHA256:
            print("Sound Watch model is ready (SHA-256 verified).")
            return
    print("Downloading the public Sound Watch model…")
    with urllib.request.urlopen(MODEL_URL, timeout=120) as response:
        model = response.read()
    if sha256(model).hexdigest() != MODEL_SHA256:
        raise SystemExit("Model checksum mismatch; refusing to bundle an unexpected model.")
    DESTINATION.parent.mkdir(parents=True, exist_ok=True)
    temporary = DESTINATION.with_suffix(".download")
    temporary.write_bytes(model)
    temporary.replace(DESTINATION)
    print("Sound Watch model downloaded and verified.")


if __name__ == "__main__":
    main()

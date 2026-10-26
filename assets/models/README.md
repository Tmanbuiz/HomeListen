# Sound Watch model

Home Listen bundles the float32 YAMNet audio classifier published by Google
MediaPipe. The input contains 15,600 mono float samples at 16 kHz; the output is
521 class scores. The label list is kept in this directory.

- Model: https://storage.googleapis.com/mediapipe-models/audio_classifier/yamnet/float32/latest/yamnet.tflite
- Labels: https://storage.googleapis.com/mediapipe-tasks/audio_classifier/yamnet_label_list.txt
- Documentation: https://ai.google.dev/edge/mediapipe/solutions/audio/audio_classifier
- YAMNet source and Apache 2.0 license: https://github.com/tensorflow/models/tree/master/research/audioset/yamnet
- Expected model SHA-256: `4d8b4a53282dc83ef04e3e7dbc4fbc98082e34e44ed798e16c3a0cdd4c584faf`

Run `python3 tool/fetch_sound_model.py` from the repository root before the first
build. If Google's `latest` artifact changes, the script rejects it until the
model has been reviewed and the pinned hash deliberately updated.

No runtime network download or cloud inference is used. Do not interpret the
classifier's scores as calibrated probabilities. Crying uses a duration rule
(30 seconds by default), preserving its timer through competing classifications
or pauses shorter than two seconds. A gap of two seconds without a matching
classification starts a fresh timer. Coughing and dog sounds require two
distinct detection runs within eight seconds, with a nonmatching classification
between them and at least 700 ms between their first detections. Repeated
overlapping windows from one continuous sound do not count as separate sounds.
Per-category cooldowns limit repeated alerts. Real sound accuracy must be
evaluated on the intended phones and in their rooms.

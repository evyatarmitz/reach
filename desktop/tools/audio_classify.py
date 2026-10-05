#!/usr/bin/env python
"""Sanity-check the sound cues against what a general audio classifier *hears*.

Runs each cue through PANNs CNN14 (AudioSet, 527 tags) and prints the top tags.
In --check mode it flags a cue whose top tags don't overlap the keywords we'd
expect for its job -- a cheap, ear-free "does this clip read as what it's for?"
pass. The model (~320MB) and the AudioSet label CSV auto-download to
~/panns_data on first run.

    python tools/audio_classify.py                 # top tags for every cue
    python tools/audio_classify.py --check         # + PASS/CHECK verdict
    python tools/audio_classify.py <file> [...]    # arbitrary files

Needs: torch, librosa, panns_inference.
"""
import os
import sys
import glob
import warnings

warnings.filterwarnings("ignore")

AUDIO_DIR = os.path.join(os.path.dirname(__file__), "..", "assets", "audio")
SR = 32000   # PANNs CNN14 sample rate
TOPK = 5

# Keywords we'd expect in a cue's top tags for it to "read" as its job. Lowercased
# substring match against AudioSet label names. Beds (ambient) get a looser net.
EXPECT = {
    "ambient":         ["ambient", "music", "drone", "wind", "new-age", "space", "synthesizer", "background"],
    "alert":           ["alarm", "beep", "siren", "buzzer", "bleep", "tone", "warning"],
    "colony_activate": ["chime", "bell", "ding", "tone", "music", "beep"],
    "construct":       ["machine", "mechanism", "tools", "engine", "motor", "whir", "sanding"],
    "fleet_build":     ["machine", "mechanism", "engine", "motor", "beep", "whir"],
    "move_order":      ["click", "beep", "blip", "tap", "tick", "pop"],
    "ui_click":        ["click", "mouse", "tick", "tap", "pop", "typing"],
    "refused":         ["buzzer", "beep", "tone", "alarm", "clang", "error"],
}


def load_model():
    from panns_inference import AudioTagging, labels
    return AudioTagging(checkpoint_path=None, device="cpu"), labels


def top_tags(at, labels, path):
    import librosa
    import numpy as np
    wav, _ = librosa.load(path, sr=SR, mono=True)
    # CNN14's pooling collapses on sub-second clips; tile a short cue up to >=1s so
    # the sound itself (not silence) is what the net sees.
    if wav.shape[0] < SR and wav.shape[0] > 0:
        wav = np.tile(wav, int(np.ceil(SR / wav.shape[0])))[:SR]
    wav = wav[None, :]
    clip, _ = at.inference(wav)
    clip = clip[0]
    idx = clip.argsort()[::-1][:TOPK]
    return [(labels[i], float(clip[i])) for i in idx]


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    check = "--check" in sys.argv

    if args:
        files = args
    else:
        files = sorted(glob.glob(os.path.join(AUDIO_DIR, "*.ogg")) +
                       glob.glob(os.path.join(AUDIO_DIR, "*.mp3")) +
                       glob.glob(os.path.join(AUDIO_DIR, "*.wav")))

    at, labels = load_model()
    for path in files:
        name = os.path.splitext(os.path.basename(path))[0]
        tags = top_tags(at, labels, path)
        tagstr = ", ".join("%s %.2f" % (t, s) for t, s in tags)
        line = "%-16s %s" % (name, tagstr)
        if check and name in EXPECT:
            want = EXPECT[name]
            hit = any(any(k in t.lower() for k in want) for t, _ in tags)
            line = ("PASS  " if hit else "CHECK ") + line
        print(line)


if __name__ == "__main__":
    main()

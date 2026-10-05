#!/usr/bin/env python3
"""Audio inspection + editing for the sound layer, usable without ears.

Why this exists: an LLM can't audition audio. This gives two things instead --
(1) ASSESS: exact durations and waveform/spectrogram PNGs that can be opened and
looked at, so "is this the right length / shape" is answerable; (2) MODIFY:
trim / loop / fade / gain / concat, the simple cut-paste-loop edits.

Pure Python (soundfile + numpy + matplotlib) -- no ffmpeg, no admin. soundfile
reads ogg/mp3/wav/flac and writes ogg/wav via its bundled libsndfile.

Usage:
  python tools/audio_tool.py info  <file...>
  python tools/audio_tool.py eval  <file...>          # does each cue fit its job?
  python tools/audio_tool.py view  <file> [out.png]
  python tools/audio_tool.py trim  <in> <out> --start S --end E   [--fade-out 0.03]
  python tools/audio_tool.py loop  <in> <out> (--dur D | --count N) [--xfade 0.0]
  python tools/audio_tool.py fade  <in> <out> [--in 0.0] [--out 0.0]
  python tools/audio_tool.py gain  <in> <out> --db X
  python tools/audio_tool.py cat   <out> <in...>

Times are seconds. Output format follows the <out> extension (.ogg or .wav).
"""
import argparse
import sys

import numpy as np
import soundfile as sf


# Expected acoustic profile per cue ROLE -- the "is this the right sound" rubric.
# dur = (min, max) seconds; attack = max seconds to reach 90% of peak (snappy vs slow);
# bright = (min, max) spectral-centroid Hz (dull..bright); loop = should be seamless.
# None means "don't check this axis". Cue names map to a role in CUE_ROLE below.
ROLE_PROFILE = {
    "click":   {"dur": (0.01, 0.20), "attack": 0.02, "bright": (1500, None), "loop": False},
    "blip":    {"dur": (0.02, 0.40), "attack": 0.05, "bright": (800, None),  "loop": False},
    "chime":   {"dur": (0.10, 0.70), "attack": 0.10, "bright": (600, None),  "loop": False},
    "alert":   {"dur": (0.05, 0.60), "attack": 0.05, "bright": (400, None),  "loop": False},
    "impact":  {"dur": (0.05, 0.80), "attack": 0.03, "bright": None,         "loop": False},
    "whoosh":  {"dur": (0.10, 0.90), "attack": 0.08, "bright": None,         "loop": False},
    "ambient": {"dur": (10.0, None), "attack": None, "bright": None,         "loop": True},
}
CUE_ROLE = {
    "ui_click": "click", "move_order": "click",
    "colony_activate": "chime", "alert": "alert", "refused": "alert",
    "construct": "impact", "fleet_build": "whoosh",
    "ambient": "ambient", "battle_loop": "ambient", "bombard_loop": "ambient",
}


def _read(path):
    data, sr = sf.read(path, always_2d=True, dtype="float32")
    return data, sr  # data: (frames, channels)


def _features(mono, sr):
    """Objective acoustic features -- the ear-replacement measurements."""
    n = len(mono)
    dur = n / sr
    peak = float(np.max(np.abs(mono))) if n else 0.0
    rms = float(np.sqrt(np.mean(mono ** 2))) if n else 0.0
    peak_db = 20 * np.log10(peak) if peak > 1e-9 else -120.0
    rms_db = 20 * np.log10(rms) if rms > 1e-9 else -120.0
    # attack: time from start to first sample within 10% of peak (on a short envelope).
    attack = 0.0
    if peak > 1e-6:
        idx = int(np.argmax(np.abs(mono) >= 0.9 * peak))
        attack = idx / sr
    # spectral centroid (brightness) over the whole clip.
    spec = np.abs(np.fft.rfft(mono)) if n else np.array([0.0])
    freqs = np.fft.rfftfreq(n, 1.0 / sr) if n else np.array([0.0])
    centroid = float(np.sum(freqs * spec) / np.sum(spec)) if np.sum(spec) > 0 else 0.0
    # spectral flatness: ~1 = noise, ~0 = tonal.
    ps = spec ** 2 + 1e-12
    flatness = float(np.exp(np.mean(np.log(ps))) / np.mean(ps))
    # loop seam: energy of the discontinuity between last and first samples, vs RMS.
    seam = abs(float(mono[-1] - mono[0])) / (rms + 1e-9) if n else 0.0
    return {"dur": dur, "peak_db": peak_db, "rms_db": rms_db, "attack": attack,
            "centroid": centroid, "flatness": flatness, "seam": seam}


def cmd_eval(args):
    import os
    print("cue              dur    peakdB  rmsdB  atk    bright  noisy  flags")
    for p in args.files:
        name = os.path.splitext(os.path.basename(p))[0]
        data, sr = _read(p)
        f = _features(data.mean(axis=1), sr)
        role = CUE_ROLE.get(name)
        prof = ROLE_PROFILE.get(role, {}) if role else {}
        flags = []
        d = prof.get("dur")
        if d:
            if d[0] is not None and f["dur"] < d[0]:
                flags.append("TOO SHORT")
            if d[1] is not None and f["dur"] > d[1]:
                flags.append("TOO LONG")
        if prof.get("attack") is not None and f["attack"] > prof["attack"]:
            flags.append("SLOW ATTACK")
        b = prof.get("bright")
        if b:
            if b[0] is not None and f["centroid"] < b[0]:
                flags.append("DULL")
            if b[1] is not None and f["centroid"] > b[1]:
                flags.append("HARSH")
        if f["peak_db"] > -0.5:
            flags.append("CLIPPY")
        if prof.get("loop") and f["seam"] > 0.5:
            flags.append("LOOP SEAM")
        role_s = role or "?"
        print("%-16s %5.2fs %6.1f %6.1f %5.3f %6.0f %6.2f  %s  [%s]" % (
            name[:16], f["dur"], f["peak_db"], f["rms_db"], f["attack"],
            f["centroid"], f["flatness"], ("OK" if not flags else ",".join(flags)), role_s))


def _write(path, data, sr):
    sf.write(path, data, sr)


def cmd_info(args):
    for p in args.files:
        try:
            i = sf.info(p)
            print(f"{p}\n  {i.duration:.3f}s  {i.samplerate}Hz  "
                  f"{i.channels}ch  {i.frames} frames  {i.format}/{i.subtype}")
        except Exception as e:
            print(f"{p}\n  ERROR: {e}")


def cmd_view(args):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    out = args.out or (args.file.rsplit(".", 1)[0] + "_view.png")
    data, sr = _read(args.file)
    mono = data.mean(axis=1)
    t = np.arange(len(mono)) / sr
    dur = len(mono) / sr

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(10, 5))
    ax1.plot(t, mono, lw=0.5, color="#1f8")
    ax1.set_title(f"{args.file}   {dur:.3f}s  {sr}Hz  peak={np.max(np.abs(mono)):.2f}")
    ax1.set_xlim(0, dur)
    ax1.set_ylim(-1, 1)
    ax1.set_ylabel("amplitude")
    ax1.grid(alpha=0.2)
    nfft = 1024 if len(mono) >= 1024 else 256
    ax2.specgram(mono, NFFT=nfft, Fs=sr, noverlap=nfft // 2, cmap="magma")
    ax2.set_ylabel("Hz")
    ax2.set_xlabel("seconds")
    fig.tight_layout()
    fig.savefig(out, dpi=90)
    print(f"wrote {out}  ({dur:.3f}s, {sr}Hz)")


def cmd_trim(args):
    data, sr = _read(args.input)
    a = int(args.start * sr)
    b = int(args.end * sr) if args.end is not None else len(data)
    a = max(0, min(a, len(data)))
    b = max(a, min(b, len(data)))
    clip = data[a:b].copy()
    if args.fade_out > 0:
        n = min(int(args.fade_out * sr), len(clip))
        if n > 0:
            clip[-n:] *= np.linspace(1.0, 0.0, n)[:, None]
    if args.fade_in > 0:
        n = min(int(args.fade_in * sr), len(clip))
        if n > 0:
            clip[:n] *= np.linspace(0.0, 1.0, n)[:, None]
    _write(args.output, clip, sr)
    print(f"wrote {args.output}  {len(clip)/sr:.3f}s  (from {args.start:.3f}-{b/sr:.3f}s)")


def cmd_loop(args):
    data, sr = _read(args.input)
    xf = int(args.xfade * sr)
    if xf > 0 and xf < len(data):
        head = data[:xf].copy()
        tail = data[-xf:].copy()
        mix = tail * np.linspace(1, 0, xf)[:, None] + head * np.linspace(0, 1, xf)[:, None]
        unit = np.concatenate([mix, data[xf:-xf]]) if len(data) > 2 * xf else data
    else:
        unit = data
    if args.count is not None:
        out = np.tile(unit, (args.count, 1))
    else:
        reps = int(np.ceil(args.dur * sr / len(unit)))
        out = np.tile(unit, (reps, 1))[: int(args.dur * sr)]
    _write(args.output, out, sr)
    print(f"wrote {args.output}  {len(out)/sr:.3f}s  (unit {len(unit)/sr:.3f}s)")


def cmd_fade(args):
    data, sr = _read(args.input)
    ni = min(int(args.in_ * sr), len(data))
    no = min(int(args.out_ * sr), len(data))
    if ni > 0:
        data[:ni] *= np.linspace(0, 1, ni)[:, None]
    if no > 0:
        data[-no:] *= np.linspace(1, 0, no)[:, None]
    _write(args.output, data, sr)
    print(f"wrote {args.output}  {len(data)/sr:.3f}s  fade in {args.in_}s out {args.out_}s")


def cmd_gain(args):
    data, sr = _read(args.input)
    data *= 10 ** (args.db / 20.0)
    np.clip(data, -1.0, 1.0, out=data)
    _write(args.output, data, sr)
    print(f"wrote {args.output}  {args.db:+.1f} dB")


def cmd_cat(args):
    sr0 = None
    parts = []
    for p in args.inputs:
        d, sr = _read(p)
        if sr0 is None:
            sr0 = sr
        elif sr != sr0:
            sys.exit(f"sample-rate mismatch: {p} is {sr}Hz, expected {sr0}Hz")
        parts.append(d)
    out = np.concatenate(parts)
    _write(args.output, out, sr0)
    print(f"wrote {args.output}  {len(out)/sr0:.3f}s  ({len(parts)} parts)")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("info"); s.add_argument("files", nargs="+"); s.set_defaults(fn=cmd_info)
    s = sub.add_parser("eval"); s.add_argument("files", nargs="+"); s.set_defaults(fn=cmd_eval)
    s = sub.add_parser("view"); s.add_argument("file"); s.add_argument("out", nargs="?"); s.set_defaults(fn=cmd_view)
    s = sub.add_parser("trim")
    s.add_argument("input"); s.add_argument("output")
    s.add_argument("--start", type=float, default=0.0)
    s.add_argument("--end", type=float, default=None)
    s.add_argument("--fade-in", dest="fade_in", type=float, default=0.0)
    s.add_argument("--fade-out", dest="fade_out", type=float, default=0.0)
    s.set_defaults(fn=cmd_trim)
    s = sub.add_parser("loop")
    s.add_argument("input"); s.add_argument("output")
    g = s.add_mutually_exclusive_group(required=True)
    g.add_argument("--dur", type=float); g.add_argument("--count", type=int)
    s.add_argument("--xfade", type=float, default=0.0)
    s.set_defaults(fn=cmd_loop)
    s = sub.add_parser("fade")
    s.add_argument("input"); s.add_argument("output")
    s.add_argument("--in", dest="in_", type=float, default=0.0)
    s.add_argument("--out", dest="out_", type=float, default=0.0)
    s.set_defaults(fn=cmd_fade)
    s = sub.add_parser("gain")
    s.add_argument("input"); s.add_argument("output"); s.add_argument("--db", type=float, required=True)
    s.set_defaults(fn=cmd_gain)
    s = sub.add_parser("cat"); s.add_argument("output"); s.add_argument("inputs", nargs="+"); s.set_defaults(fn=cmd_cat)

    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()

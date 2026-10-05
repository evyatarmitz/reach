#!/usr/bin/env python
"""Build a long, seamlessly-looping ambient bed from a short source clip.

A 70s loop is painfully obvious after a few minutes of play. Instead of just
repeating it, we layer the source at several *incommensurate* playback speeds
(each a different, non-dividing ratio) with different start offsets, one layer
reversed. Each layer loops at its own period (70s / speed), so the combined
texture only truly repeats at the least-common-multiple of those periods --
far longer than the target length. Within the exported window a listener never
hears the same ~70s arrangement twice.

Finally the tail is equal-power crossfaded into the head so the exported file
itself loops with no seam.

Pure numpy + soundfile (libsndfile decodes mp3, encodes OGG/Vorbis).

    python tools/stitch_ambient.py [src] [out] [minutes]
"""
import sys
import numpy as np
import soundfile as sf

SRC = sys.argv[1] if len(sys.argv) > 1 else "assets/audio/ambient.mp3"
OUT = sys.argv[2] if len(sys.argv) > 2 else "assets/audio/ambient.ogg"
MINUTES = float(sys.argv[3]) if len(sys.argv) > 3 else 10.0

# (speed, start-offset seconds, gain, reversed?). Speeds are deliberately odd
# ratios so no two layers share a loop period; the 0.5x layer adds a sub-octave
# drone for body.
LAYERS = [
    (1.000, 0.0,  1.00, False),
    (0.937, 23.0, 0.80, False),
    (1.061, 47.0, 0.70, True),
    (0.841, 11.0, 0.55, False),
    (0.500, 37.0, 0.45, False),
]
XFADE_S = 8.0          # loop-seam crossfade
CHUNK = 1 << 20        # frames per processing chunk


def main() -> None:
    src, sr = sf.read(SRC, always_2d=True, dtype="float32")
    slen = src.shape[0]
    rev = src[::-1].copy()
    out_n = int(round(MINUTES * 60 * sr))
    xf = int(round(XFADE_S * sr))
    total = out_n + xf                      # extra tail folded back into the head
    mix = np.zeros((total, src.shape[1]), dtype=np.float32)

    for speed, off_s, gain, reverse in LAYERS:
        buf = rev if reverse else src
        off = off_s * sr
        start = 0
        while start < total:
            n = min(CHUNK, total - start)
            # source read position for each output frame, wrapping around the clip
            pos = (np.arange(start, start + n, dtype=np.float64) * speed + off) % slen
            i0 = np.floor(pos).astype(np.int64)
            frac = (pos - i0).astype(np.float32)[:, None]
            i1 = (i0 + 1) % slen
            seg = buf[i0] * (1.0 - frac) + buf[i1] * frac
            mix[start:start + n] += seg.astype(np.float32) * gain
            start += n

    # Slow breathing LFO so the overall level drifts (~90s cycle), masking structure.
    t = np.arange(total, dtype=np.float64) / sr
    lfo = (0.85 + 0.15 * np.sin(2 * np.pi * t / 90.0)).astype(np.float32)[:, None]
    mix *= lfo

    # Normalise to a safe peak.
    peak = float(np.max(np.abs(mix)))
    if peak > 0:
        mix *= 0.89 / peak

    # Fold the tail into the head with an equal-power crossfade -> seamless loop.
    head = mix[:out_n].copy()
    tail = mix[out_n:out_n + xf]
    fade = np.linspace(0, np.pi / 2, xf, dtype=np.float32)
    fin = np.sin(fade)[:, None]
    fout = np.cos(fade)[:, None]
    head[:xf] = head[:xf] * fin + tail * fout

    # Write in blocks: handing libsndfile's Vorbis encoder the whole buffer in one
    # call overflows the native stack, so stream it.
    with sf.SoundFile(OUT, "w", samplerate=sr, channels=head.shape[1],
                      format="OGG", subtype="VORBIS") as f:
        for i in range(0, head.shape[0], 1 << 15):
            f.write(np.ascontiguousarray(head[i:i + (1 << 15)]))
    dur = out_n / sr
    print(f"wrote {OUT}  {dur:.1f}s  {sr}Hz  {src.shape[1]}ch  "
          f"from {slen/sr:.1f}s source x{len(LAYERS)} layers, {XFADE_S:.0f}s seam")


if __name__ == "__main__":
    main()

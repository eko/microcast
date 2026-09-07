#!/usr/bin/env python3
"""Renders a music bed for a radio jingle.

The generated-sound APIs produce texture rather than tunes, so beds that need an
actual melody are synthesised here instead. The arrangement follows the conventions
of station imaging rather than those of a song: a wide detuned chord stack, pads and
bass pumping against the kick, a filter that opens as the bed builds, a drum fill into
the last bar, and a logo bar that lands resolved on the tonic.

    Tools/make-bed.py out.wav --style chr
    Tools/make-bed.py out.wav --style dance --variants 4

Every seed rewrites the hook, the rhythm and the fills, so variants of one style stay
in character without repeating themselves.

Styles: chr, dance, edm, urban, hotac, retro, epic, chill, news.
"""

import argparse
import math
import random
import struct
import wave

RATE = 44100

MAJOR = [0, 4, 7]
MINOR = [0, 3, 7]
SUS4 = [0, 5, 7]
MAJ7 = [0, 4, 7, 11]
MIN7 = [0, 3, 7, 10]

# Motifs are indices into the chord's tones rather than fixed notes, so a hook stays
# in key across any progression and any transposition.
MOTIFS = [
    [0, 1, 2, 1], [2, 1, 0, 1], [0, 2, 1, 3], [3, 2, 1, 0],
    [0, 1, 3, 2], [1, 0, 2, 3], [2, 3, 4, 3], [0, 3, 2, 4],
    [4, 2, 3, 1], [0, 2, 4, 2], [1, 3, 2, 4], [2, 0, 3, 1],
]
# Resolving motifs end on the tonic; the logo bar always uses one of these.
CADENCES = [[2, 1, 0, 0], [3, 2, 1, 0], [1, 2, 1, 0], [4, 3, 2, 0]]

# Onsets in beats within a bar.
RHYTHMS = [
    [0, 1, 2, 3], [0, 0.5, 1.5, 2.5], [0, 0.75, 1.5, 2.25],
    [0, 1, 1.5, 2.5], [0, 0.5, 1, 2], [0, 1, 2, 2.5],
]

STYLES = {
    # Contemporary hit radio: bright, wide, hard pump.
    "chr": dict(
        chords=[(65, MAJOR), (72, MAJOR), (69, MINOR), (65, MAJOR)], bpm=128, base_oct=1,
        lead_wave="saw", lead_amp=0.26, lead_voices=7, lead_detune=16,
        pad_amp=0.20, pad_voices=7, pad_wave="saw", bass_amp=0.34, bass_mode="beat",
        cut_base=1100, cut_peak=6200, pump=0.72,
        kick=True, clap=True, snare=False, hats="16", fill=True, riser=True, crash=True, arp=False),
    # House: offbeat bass, longer build.
    "dance": dict(
        chords=[(69, MIN7), (65, MAJ7), (72, MAJOR), (67, MAJOR)], bpm=126, base_oct=1,
        lead_wave="saw", lead_amp=0.22, lead_voices=7, lead_detune=20,
        pad_amp=0.24, pad_voices=7, pad_wave="saw", bass_amp=0.32, bass_mode="offbeat",
        cut_base=800, cut_peak=5200, pump=0.80,
        kick=True, clap=True, snare=False, hats="16", fill=True, riser=True, crash=True, arp=True),
    # Festival EDM: the loudest, most aggressive read.
    "edm": dict(
        chords=[(69, MINOR), (65, MAJOR), (60, MAJOR), (67, MAJOR)], bpm=130, base_oct=2,
        lead_wave="saw", lead_amp=0.30, lead_voices=7, lead_detune=26,
        pad_amp=0.18, pad_voices=7, pad_wave="saw", bass_amp=0.38, bass_mode="sixteenth",
        cut_base=1400, cut_peak=7000, pump=0.85,
        kick=True, clap=True, snare=False, hats="16", fill=True, riser=True, crash=True, arp=False),
    # Urban: sparse, 808-led, halftime feel.
    "urban": dict(
        chords=[(69, MIN7), (67, MINOR), (65, MAJ7), (69, MIN7)], bpm=96, base_oct=1,
        lead_wave="tri", lead_amp=0.26, lead_voices=3, lead_detune=8,
        pad_amp=0.18, pad_voices=5, pad_wave="saw", bass_amp=0.46, bass_mode="octave",
        cut_base=900, cut_peak=3800, pump=0.30,
        kick=True, clap=False, snare=True, hats="16", fill=True, riser=False, crash=True, arp=False),
    # Hot AC: friendly, plucked, mid-tempo.
    "hotac": dict(
        chords=[(65, MAJOR), (60, SUS4), (69, MINOR), (65, MAJOR)], bpm=112, base_oct=1,
        lead_wave="tri", lead_amp=0.30, lead_voices=3, lead_detune=9,
        pad_amp=0.20, pad_voices=5, pad_wave="saw", bass_amp=0.30, bass_mode="beat",
        cut_base=1200, cut_peak=4200, pump=0.35,
        kick=True, clap=True, snare=False, hats="8", fill=False, riser=False, crash=True, arp=False),
    # Synthwave.
    "retro": dict(
        chords=[(65, MAJOR), (60, MAJOR), (67, MAJOR), (65, MAJOR)], bpm=118, base_oct=1,
        lead_wave="square", lead_amp=0.22, lead_voices=5, lead_detune=22,
        pad_amp=0.22, pad_voices=7, pad_wave="saw", bass_amp=0.36, bass_mode="sixteenth",
        cut_base=900, cut_peak=4200, pump=0.45,
        kick=True, clap=False, snare=True, hats="8", fill=True, riser=False, crash=True, arp=True),
    # Epic: brass-ish stabs and a big tail, for a launch or an event.
    "epic": dict(
        chords=[(60, MINOR), (65, MINOR), (67, MAJOR), (60, MINOR)], bpm=100, base_oct=2,
        lead_wave="saw", lead_amp=0.30, lead_voices=7, lead_detune=12,
        pad_amp=0.26, pad_voices=7, pad_wave="saw", bass_amp=0.40, bass_mode="beat",
        cut_base=700, cut_peak=5000, pump=0.25,
        kick=True, clap=False, snare=True, hats="none", fill=True, riser=True, crash=True, arp=False),
    # Chill: soft, no kit to speak of, for a night slot.
    "chill": dict(
        chords=[(65, MAJ7), (69, MIN7), (62, MIN7), (67, MAJOR)], bpm=104, base_oct=1,
        lead_wave="sine", lead_amp=0.30, lead_voices=3, lead_detune=6,
        pad_amp=0.26, pad_voices=7, pad_wave="saw", bass_amp=0.28, bass_mode="beat",
        cut_base=800, cut_peak=2800, pump=0.20,
        kick=True, clap=False, snare=False, hats="8", fill=False, riser=False, crash=False, arp=True),
    # News and talk: urgency, no kit, clean resolution.
    "news": dict(
        chords=[(60, MAJOR), (67, MAJOR), (65, MAJOR), (60, MAJOR)], bpm=120, base_oct=2,
        lead_wave="sine", lead_amp=0.34, lead_voices=1, lead_detune=0,
        pad_amp=0.26, pad_voices=5, pad_wave="saw", bass_amp=0.30, bass_mode="beat",
        cut_base=2000, cut_peak=6500, pump=0.0,
        kick=False, clap=False, snare=False, hats="none", fill=False, riser=False, crash=False, arp=False),
}


def midi_to_freq(note: int) -> float:
    return 440.0 * 2 ** ((note - 69) / 12)


def poly_blep(t: float, dt: float) -> float:
    """Correction term that band-limits a waveform's discontinuities.

    A naive saw or square folds every harmonic above Nyquist back down as an
    inharmonic whine, which is what makes cheap synthesis sound brittle. Rounding
    each jump over one sample removes most of it for a fraction of the cost of
    additive synthesis.
    """
    if t < dt:
        t /= dt
        return t + t - t * t - 1.0
    if t > 1.0 - dt:
        t = (t - 1.0) / dt
        return t * t + t + t + 1.0
    return 0.0


def osc(shape: str, phase: float, dt: float) -> float:
    if shape == "sine":
        return math.sin(2 * math.pi * phase)
    if shape == "tri":
        return 4 * abs(phase - 0.5) - 1
    if shape == "saw":
        return (2.0 * phase - 1.0) - poly_blep(phase, dt)
    if shape == "square":
        v = 1.0 if phase < 0.5 else -1.0
        return v + poly_blep(phase, dt) - poly_blep((phase + 0.5) % 1.0, dt)
    raise ValueError(shape)


def add_note(buf, start, dur, freq, amp, shape="saw", attack=0.005, decay=None,
             voices=1, detune_cents=0.0):
    """Mixes an enveloped note in, stacking detuned voices to widen it."""
    i0 = int(start * RATE)
    if i0 >= len(buf) or freq <= 0:
        return
    n = min(int(dur * RATE), len(buf) - i0)
    decay = dur if decay is None else decay

    if voices > 1:
        cents = [detune_cents * (2 * v / (voices - 1) - 1) for v in range(voices)]
    else:
        cents = [0.0]
    dts = [min(freq * 2 ** (c / 1200) / RATE, 0.49) for c in cents]
    # Random start phases stop the stack from summing into one clicky transient.
    phases = [random.random() for _ in dts]
    gain = amp / math.sqrt(len(dts))

    for i in range(n):
        t = i / RATE
        env = min(t / attack, 1.0) if attack > 0 else 1.0
        env *= math.exp(-t / decay)
        # The envelope is legitimately zero at the first sample of the attack, so only
        # give up once the note is actually decaying.
        if t > attack and env < 1e-4:
            break
        acc = 0.0
        for k, dt in enumerate(dts):
            p = phases[k] + dt
            if p >= 1.0:
                p -= 1.0
            phases[k] = p
            acc += osc(shape, p, dt)
        buf[i0 + i] += gain * env * acc


def add_kick(buf, start, amp=1.0):
    i0 = int(start * RATE)
    n = min(int(0.30 * RATE), len(buf) - i0)
    phase = 0.0
    for i in range(max(n, 0)):
        t = i / RATE
        phase += (48 + 78 * math.exp(-t / 0.028)) / RATE
        buf[i0 + i] += amp * math.exp(-t / 0.11) * math.sin(2 * math.pi * phase)


def add_clap(buf, start, amp=0.42):
    for offset, g in ((0.0, 0.7), (0.011, 0.85), (0.023, 1.0)):
        i0 = int((start + offset) * RATE)
        n = min(int(0.18 * RATE), len(buf) - i0)
        for i in range(max(n, 0)):
            t = i / RATE
            buf[i0 + i] += amp * g * math.exp(-t / 0.045) * (random.random() * 2 - 1)


def add_snare(buf, start, amp=0.40):
    """Noise for the wires plus a short tone for the body."""
    i0 = int(start * RATE)
    n = min(int(0.22 * RATE), len(buf) - i0)
    phase = 0.0
    for i in range(max(n, 0)):
        t = i / RATE
        phase += 190 / RATE
        env = math.exp(-t / 0.055)
        buf[i0 + i] += amp * env * (0.75 * (random.random() * 2 - 1)
                                    + 0.35 * math.sin(2 * math.pi * phase))


def add_hat(buf, start, amp=0.16, decay=0.012):
    i0 = int(start * RATE)
    n = min(int(0.07 * RATE), len(buf) - i0)
    for i in range(max(n, 0)):
        buf[i0 + i] += amp * math.exp(-(i / RATE) / decay) * (random.random() * 2 - 1)


def add_crash(buf, start, amp=0.30):
    i0 = int(start * RATE)
    n = min(int(1.8 * RATE), len(buf) - i0)
    for i in range(max(n, 0)):
        buf[i0 + i] += amp * math.exp(-(i / RATE) / 0.60) * (random.random() * 2 - 1)


def add_fill(buf, start, beat, kind, snare=True):
    """A roll into the next bar. Accelerating, and rising in level."""
    steps = {"sixteenths": 8, "triplets": 6, "accel": 10}[kind]
    for j in range(steps):
        frac = j / steps
        pos = start + (frac ** (0.75 if kind == "accel" else 1.0)) * beat * 2
        amp = 0.18 + 0.34 * frac
        if snare:
            add_snare(buf, pos, amp)
        else:
            add_hat(buf, pos, amp * 0.7, decay=0.02)


def add_riser(buf, start, dur, amp=0.34):
    i0 = int(start * RATE)
    n = min(int(dur * RATE), len(buf) - i0)
    if n <= 0:
        return
    phase = 0.0
    for i in range(n):
        t = i / RATE
        frac = t / dur
        phase += (280 * 2 ** (3.2 * frac)) / RATE
        buf[i0 + i] += amp * (frac ** 2) * (0.7 * (random.random() * 2 - 1)
                                            + 0.3 * math.sin(2 * math.pi * phase))


def lowpass_2pole(buf, cutoff_at):
    """Two cascaded one-poles: 12 dB per octave, and unconditionally stable.

    cutoff_at(t) returns the corner frequency, so the filter can open as the bed
    builds — the sweep that makes an intro feel like it is going somewhere.
    """
    z1 = z2 = 0.0
    for i in range(len(buf)):
        fc = cutoff_at(i / RATE)
        a = 1 - math.exp(-2 * math.pi * min(fc, RATE * 0.45) / RATE)
        z1 += a * (buf[i] - z1)
        z2 += a * (z1 - z2)
        buf[i] = z2


def apply_pump(buf, beat, depth, until):
    """Ducks the harmonic parts against every kick."""
    if depth <= 0:
        return
    tau = beat * 0.28
    for i in range(len(buf)):
        t = i / RATE
        if t > until:
            break
        buf[i] *= 1.0 - depth * math.exp(-(t % beat) / tau)


def reverb(buf, mix=0.20):
    """Schroeder reverb: parallel combs for density, allpasses to smear the ring."""
    n = len(buf)
    wet = [0.0] * n
    for delay_ms, fb in ((29.7, 0.79), (37.1, 0.81), (41.1, 0.77), (43.7, 0.75)):
        d = int(delay_ms * RATE / 1000)
        tmp = list(buf)
        for i in range(d, n):
            tmp[i] += fb * tmp[i - d]
        for i in range(n):
            wet[i] += 0.25 * tmp[i]
    for delay_ms, g in ((5.0, 0.7), (1.7, 0.7)):
        d = int(delay_ms * RATE / 1000)
        out = list(wet)
        for i in range(d, n):
            out[i] = -g * wet[i] + wet[i - d] + g * out[i - d]
        wet = out
    for i in range(n):
        buf[i] += mix * wet[i]


def chord_tones(intervals):
    """The chord across two octaves, for motifs to walk through."""
    return intervals + [i + 12 for i in intervals] + [intervals[0] + 24]


def render(style_name: str, bars: int, bpm: float, seed: int):
    # Derive from style and seed together, so one seed does not hand every style
    # the same arrangement. A string seed is stable across runs, unlike hash().
    rng = random.Random(f"{style_name}:{seed}")
    random.seed(f"{style_name}:{seed}:noise")
    s = STYLES[style_name]
    beat = 60.0 / bpm
    bar = 4 * beat
    groove_end = bars * bar
    total = groove_end + 2.4
    n = int(total * RATE)

    music = [0.0] * n          # pads, bass and lead: these pump
    drums = [0.0] * n
    noise = [0.0] * n

    # The seed picks the arrangement, so variants of a style differ in substance
    # rather than in tuning.
    motifs = [rng.choice(MOTIFS) for _ in range(max(bars - 1, 1))]
    motifs.append(rng.choice(CADENCES))
    rhythm = rng.choice(RHYTHMS)
    fill_kind = rng.choice(["sixteenths", "triplets", "accel"])
    lead_oct = s["base_oct"] + rng.choice([0, 0, 1])
    arp_on = s["arp"] and rng.random() < 0.7
    rotation = rng.choice([0, 0, 1, 3])          # which chord the bed opens on
    # An ident that starts at full intensity has nowhere left to go, so the
    # arrangement builds, and the seed decides how it gets there.
    shape = rng.choice(["build", "break", "full"])

    def bar_plan(b):
        last = b == bars - 1
        if shape == "break" and b == bars - 2:
            # Dropping the kit for a bar makes the last bar land much harder.
            return dict(kick=False, perc=False, hats=False, amp=0.72)
        if shape == "build" and not last:
            return dict(kick=True, perc=b >= 2, hats=b >= 1,
                        amp=0.78 + 0.22 * b / max(bars - 1, 1))
        return dict(kick=True, perc=True, hats=True, amp=1.0)

    for b in range(bars):
        t0 = b * bar
        root, intervals = s["chords"][(b + rotation) % len(s["chords"])]
        tones = chord_tones(intervals)
        last = b == bars - 1
        plan = bar_plan(b)

        # Bass.
        mode = s["bass_mode"]
        if mode == "offbeat" and not last:
            onsets = [(i + 0.5) * beat for i in range(4)]
            hold = beat * 0.38
        elif mode == "sixteenth":
            onsets = [i * beat / 2 for i in range(8)]
            hold = beat * 0.30
        elif mode == "octave":
            onsets = [0, 1.5 * beat, 2 * beat, 3.5 * beat]
            hold = beat * 0.55
        else:
            onsets = [i * beat for i in range(4)]
            hold = beat * 0.80
        for j, o in enumerate(onsets):
            octave = 12 if (mode == "octave" and j % 2) else 0
            add_note(music, t0 + o, hold, midi_to_freq(root - 24 + octave),
                     s["bass_amp"], "sine", decay=beat * 0.42)

        # Pad, or a sixteenth arpeggio through the chord when the style arps.
        if arp_on and not last:
            for j in range(16):
                note = root + tones[j % len(tones)] + 12 * s["base_oct"]
                add_note(music, t0 + j * beat / 4, beat * 0.30, midi_to_freq(note),
                         s["pad_amp"] * 0.8 * plan["amp"], s["pad_wave"], decay=beat * 0.18,
                         voices=3, detune_cents=10)
        else:
            for iv in intervals:
                add_note(music, t0, bar * 0.98, midi_to_freq(root + iv),
                         s["pad_amp"] / len(intervals) * plan["amp"], s["pad_wave"], attack=0.03,
                         decay=bar * 0.9, voices=s["pad_voices"], detune_cents=13)

        # Hook: the motif walked through this bar's chord, on the seed's rhythm.
        notes = [root + tones[i % len(tones)] + 12 * lead_oct for i in motifs[b % len(motifs)]]
        for j, note in enumerate(notes):
            onset = rhythm[j % len(rhythm)] * beat
            hold = beat * (1.6 if (last and j == len(notes) - 1) else 0.85)
            # Accent the downbeat: flat velocities are what make a part sound typed in.
            amp = s["lead_amp"] * plan["amp"] * (1.0 if onset < 0.01 else 0.82)
            add_note(music, t0 + onset, hold, midi_to_freq(note), amp,
                     s["lead_wave"], decay=beat * 0.55,
                     voices=s["lead_voices"], detune_cents=s["lead_detune"])

        if s["kick"] and plan["kick"]:
            for i in range(4):
                add_kick(drums, t0 + i * beat)
        if s["clap"] and plan["perc"]:
            for i in (1, 3):
                add_clap(drums, t0 + i * beat)
        if s["snare"] and plan["perc"]:
            for i in (1, 3):
                add_snare(drums, t0 + i * beat)
        if s["hats"] != "none" and plan["hats"]:
            step = beat / 2 if s["hats"] == "8" else beat / 4
            k = 0
            t = 0.0
            while t < bar - 1e-6:
                if not (s["hats"] == "8" and k % 2 == 0):
                    add_hat(drums, t0 + t, 0.16 if k % 2 else 0.10)
                t += step
                k += 1
        if s["crash"] and b == 0:
            add_crash(noise, t0)
        if s["fill"] and last:
            add_fill(drums, t0 - 2 * beat, beat, fill_kind, snare=s["snare"] or s["clap"])
        if s["riser"] and last:
            add_riser(noise, t0 - bar, bar)

    # The logo: the tonic, stated and left to ring.
    root, intervals = s["chords"][rotation % len(s["chords"])]
    for iv in intervals + [12, 19]:
        add_note(music, groove_end, 2.2, midi_to_freq(root + iv),
                 0.24 / (len(intervals) + 2), s["pad_wave"], attack=0.004, decay=0.95,
                 voices=s["pad_voices"], detune_cents=13)
    add_note(music, groove_end, 2.2, midi_to_freq(root - 24), 0.36, "sine", decay=0.8)
    if s["kick"]:
        add_kick(drums, groove_end)
    if s["crash"]:
        add_crash(noise, groove_end, amp=0.34)

    # The filter opens across the groove, then stays open for the logo.
    base, peak = s["cut_base"], s["cut_peak"]

    def cutoff_at(t):
        if t >= groove_end:
            return peak
        frac = min(t / max(groove_end - bar, bar), 1.0)
        return base + (peak - base) * (frac ** 0.7)

    lowpass_2pole(music, cutoff_at)
    apply_pump(music, beat, s["pump"], groove_end)

    high = list(noise)
    lowpass_2pole(high, lambda _t: 900)
    for i in range(n):
        noise[i] -= high[i]

    buf = [music[i] + drums[i] + noise[i] for i in range(n)]
    reverb(buf)

    peak_v = max(abs(v) for v in buf) or 1.0
    scale = 0.89 / peak_v
    samples = [math.tanh(1.1 * v * scale) * 0.92 for v in buf]
    info = (f"shape={shape} rotation={rotation} rhythm={rhythm} "
            f"fill={fill_kind} lead_oct={lead_oct} arp={arp_on}")
    return samples, info


def write_wav(path, mono):
    """Writes stereo, delaying one side slightly to widen the image."""
    off = int(0.009 * RATE)
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        frames = bytearray()
        for i, v in enumerate(mono):
            right = mono[i - off] if i >= off else v
            frames += struct.pack("<hh", int(v * 32000), int(0.85 * right * 32000))
        w.writeframes(bytes(frames))


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("out")
    p.add_argument("--style", default="chr", choices=sorted(STYLES))
    p.add_argument("--bars", type=int, default=4)
    p.add_argument("--bpm", type=float, default=0, help="0 uses the style's own tempo")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--variants", type=int, default=1,
                   help="render N seeds, numbering the output files")
    a = p.parse_args()

    bpm = a.bpm or STYLES[a.style]["bpm"]
    for k in range(a.variants):
        seed = a.seed + k
        out = a.out
        if a.variants > 1:
            stem, _, ext = a.out.rpartition(".")
            out = f"{stem}-{seed}.{ext}" if stem else f"{a.out}-{seed}"
        samples, info = render(a.style, a.bars, bpm, seed)
        write_wav(out, samples)
        print(f"{out}  style={a.style} bpm={bpm:g} seed={seed}  {info}")


if __name__ == "__main__":
    main()

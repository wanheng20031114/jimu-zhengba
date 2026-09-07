"""Original synthesized foley and restrained medieval ambience for Ashen Crown.

No external recordings, samples, model output or copyrighted music are used.
48 kHz mono PCM16; deterministic synthesis, short endpoint fades, no clipping.
"""
from pathlib import Path
import json
import math
import wave
import numpy as np
from scipy import signal

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets/audio"
OUT.mkdir(parents=True, exist_ok=True)
SR = 48000
RNG = np.random.default_rng(849271)


def timebase(duration):
    return np.arange(round(duration * SR), dtype=np.float64) / SR


def filt(values, cutoff, mode="lowpass", order=3):
    sos = signal.butter(order, cutoff, btype=mode, fs=SR, output="sos")
    return signal.sosfilt(sos, values)


def noise(duration, band=(80, 2500)):
    values = RNG.standard_normal(round(duration * SR))
    values = filt(values, band, "bandpass", 3)
    return values / (np.std(values) + 1e-12)


def envelope(t, attack=.003, decay=.14):
    return np.minimum(1.0, t / attack) * np.exp(-t / decay)


def modal(duration, frequencies, decay=.16, amplitudes=None):
    t = timebase(duration)
    if amplitudes is None:
        amplitudes = [1.0 / (1.0 + index * .7) for index in range(len(frequencies))]
    value = np.zeros_like(t)
    for index, (freq, amp) in enumerate(zip(frequencies, amplitudes)):
        value += amp * np.sin(math.tau * freq * t + .2 * index) * envelope(t, .0015, decay / (1 + index * .10))
    return value


def add(buffer, sound, at, gain=1.0, wrap=False):
    start = int(round(at * SR))
    if wrap:
        indices = (np.arange(len(sound)) + start) % len(buffer)
        np.add.at(buffer, indices, sound * gain)
    elif start < len(buffer):
        count = min(len(sound), len(buffer) - start)
        buffer[start:start + count] += sound[:count] * gain


def room(values, taps=((.031, .16), (.067, .10), (.109, .055)), cutoff=1900):
    soft = filt(values, cutoff)
    out = values.copy()
    for delay, amount in taps:
        offset = round(delay * SR)
        out[offset:] += soft[:-offset] * amount
    return out


def pluck(frequency, duration=2.3, decay=1.05, brightness=.50):
    """A damped, mildly inharmonic gut-string mode bank with a wooden body."""
    t = timebase(duration)
    value = np.zeros_like(t)
    for harmonic in range(1, 14):
        partial = frequency * harmonic * math.sqrt(1 + .00009 * harmonic * harmonic)
        damping = (1 / decay) + (harmonic - 1) * (1.05 - brightness)
        value += np.sin(math.tau * partial * t) * np.exp(-t * damping) / harmonic ** 1.65
    value += .065 * noise(duration, (180, 1200)) * envelope(t, .002, .018)
    return value * np.minimum(1.0, t / .005)


def sword_hit():
    duration = .46
    t = timebase(duration)
    ring = modal(duration, [438, 783, 1281, 1877, 2483, 3191], .115,
                 [.52, .73, .44, .20, .12, .045])
    impact = .62 * noise(duration, (160, 1800)) * envelope(t, .0008, .014)
    air = .14 * noise(duration, (1600, 4800)) * envelope(t, .001, .022)
    return room(ring + impact + air, cutoff=2200)


def arrow_hit():
    duration = .34
    t = timebase(duration)
    # Brief fiber-string release followed by a dry, woody contact.
    phase = math.tau * (230 * t + 54 * .034 * (1 - np.exp(-t / .034)))
    twang = .30 * np.sin(phase) * envelope(t, .001, .043)
    woody = .52 * modal(duration, [273, 492, 823, 1377], .061)
    brush = .10 * noise(duration, (1500, 4200)) * envelope(t, .001, .030)
    return room(twang + woody + brush, taps=((.022, .08),), cutoff=1200)


def cannon():
    duration = 2.35
    t = timebase(duration)
    blast = noise(duration, (38, 320)) * envelope(t, .0015, .33)
    pressure = .75 * noise(duration, (75, 1450)) * envelope(t, .0006, .077)
    crack = .16 * noise(duration, (600, 3800)) * envelope(t, .0007, .019)
    phase = math.tau * (38 * t + (112 - 38) * .075 * (1 - np.exp(-t / .075)))
    chest = 1.30 * np.sin(phase) * envelope(t, .002, .25)
    rumble = .43 * noise(duration, (30, 160)) * envelope(t, .10, .52)
    value = blast + pressure + crack + chest + rumble
    return room(value, taps=((.075, .24), (.145, .15), (.231, .09), (.393, .04)), cutoff=900)


def stone_hit():
    duration = 1.15
    t = timebase(duration)
    value = .88 * noise(duration, (55, 1000)) * envelope(t, .001, .095)
    value += .60 * modal(duration, [87, 173, 319, 533], .14)
    # Gravel bounces with decreasing weight and irregular inter-impact timing.
    for at, weight in ((.08,.23),(.17,.17),(.285,.12),(.39,.10),(.56,.075),(.77,.045)):
        chip = modal(.24, [RNG.uniform(370, 520), RNG.uniform(760, 1300)], .038)
        chip += noise(.24, (260, 2100)) * envelope(timebase(.24), .001, .022) * .35
        add(value, chip, at, weight)
    return room(value, cutoff=1250)


def collapse():
    duration = 2.45
    t = timebase(duration)
    value = .22 * noise(duration, (40, 720)) * envelope(t, .16, .64)
    for index, at in enumerate([0, .045, .118, .21, .32, .46, .63, .82, 1.02, 1.24, 1.49, 1.78, 2.07]):
        age = index / 12.0
        decay = .115 - age * .050
        chip_t = timebase(.34)
        shard = .46 * noise(.34, (90 + age * 250, 1700)) * envelope(chip_t, .001, decay)
        shard += .33 * modal(.34, [RNG.uniform(105, 240), RNG.uniform(290, 580), RNG.uniform(700, 1100)], decay)
        add(value, shard, at, (1 - age * .82) * RNG.uniform(.75, 1.15))
    # Short dry beam creaks, low enough to avoid a synthetic whistle.
    for at, frequency in ((.18, 132), (.61, 108), (1.12, 157)):
        creak_t = timebase(.32)
        creak = signal.sawtooth(math.tau * (frequency * creak_t + 2 * np.sin(math.tau * 8 * creak_t)), width=.8)
        creak = filt(creak, 650) * np.sin(np.pi * np.arange(len(creak)) / (len(creak) - 1)) ** 2
        add(value, creak, at, .055)
    return room(value, taps=((.053,.18),(.123,.13),(.245,.06)), cutoff=1300)


def select_sound():
    duration = .18
    t = timebase(duration)
    return .70 * modal(duration, [482, 956, 1421], .020) + .22 * noise(duration, (220, 1800)) * envelope(t, .001, .009)


def order_sound():
    value = np.zeros(round(.29 * SR))
    add(value, modal(.18, [330, 660, 995], .040), 0, .55)
    add(value, modal(.18, [440, 881, 1323], .047), .055, .38)
    return value


def recruit():
    value = np.zeros(round(.87 * SR))
    # A short open fifth suggests a medieval horn/string acknowledgement.
    for at, note, volume in ((0, 146.832, .60), (.09, 220.0, .43), (.18, 293.665, .35)):
        add(value, pluck(note, .69, .19, .32), at, volume)
    return room(value, cutoff=1200)


def coin():
    value = np.zeros(round(.49 * SR))
    add(value, modal(.37, [1094, 1682, 2519, 3291], .078, [.65,.35,.15,.04]), 0, .60)
    add(value, modal(.32, [986, 1473, 2171], .057, [.55,.3,.08]), .073, .31)
    return room(value, taps=((.038,.065),), cutoff=1600)


def ambient_wind():
    duration = 32.0
    count = round(duration * SR)
    frequencies = np.fft.rfftfreq(count, 1 / SR)
    phase = RNG.uniform(0, math.tau, len(frequencies))
    # Circular spectral noise is periodic by construction, without a seam.
    magnitude = np.zeros_like(frequencies)
    region = (frequencies >= 38) & (frequencies < 1900)
    magnitude[region] = 1 / np.maximum(frequencies[region], 38) ** .84
    magnitude *= np.exp(-(frequencies / 950) ** 4)
    values = np.fft.irfft(magnitude * np.exp(1j * phase), n=count)
    values /= np.std(values)
    t = np.arange(count) / SR
    gusts = .47 + .14 * np.sin(math.tau * t / 16.0 + .4) + .13 * np.sin(math.tau * t / 8.0 + 1.7)
    return values * gusts


def ambient_music():
    duration = 32.0
    value = np.zeros(round(duration * SR))
    # Eight original, sparse 4-second phrases: Dm, Bb, F, C, Dm, Gm, Bb, Dm.
    chords = [(50,57,62,65),(46,53,58,62),(53,60,65,69),(48,55,60,64),
              (50,57,62,65),(43,50,55,58),(46,53,58,62),(50,57,62,65)]
    melody = [(0.2,62),(2.4,65),(4.4,62),(6.6,58),(8.3,60),(10.7,65),
              (12.4,64),(14.6,60),(16.2,62),(18.5,57),(20.4,58),(22.6,55),
              (24.3,58),(26.4,62),(28.2,65),(30.3,62)]
    for bar, chord in enumerate(chords):
        for tick, note in enumerate(chord[:3]):
            frequency = 440 * 2 ** ((note - 69) / 12)
            add(value, pluck(frequency, 3.6, 1.17, .28), bar * 4 + tick * .75,
                [.12,.065,.045][tick], wrap=True)
        # Quiet bowed lower root/fifth, shaped gently within each phrase.
        t = timebase(5.0)
        env = np.sin(np.pi * np.clip(t / 5.0, 0, 1)) ** 2
        for note, gain in ((chord[0] - 12, .042),(chord[1] - 12, .016)):
            frequency = 440 * 2 ** ((note - 69) / 12)
            voice = np.zeros_like(t)
            for harmonic in range(1, 7):
                vibrato = .008 * np.sin(math.tau * 4.5 * t) * harmonic
                voice += np.sin(math.tau * frequency * harmonic * t + vibrato) / harmonic ** 1.9
            add(value, voice * env, bar * 4 - .4, gain, wrap=True)
    for at, note in melody:
        add(value, pluck(440 * 2 ** ((note - 69) / 12), 3.8, 1.32, .34), at, .045, wrap=True)
    # Periodic, softly filtered early reflections, no hiss or long synthetic tail.
    dry = value.copy()
    for delay, gain in ((.083,.13),(.173,.075),(.291,.035)):
        value += np.roll(dry, round(delay * SR)) * gain
    return filt(value, 3100)


def export(name, values, peak, loop=False, description=""):
    values = np.asarray(values, dtype=np.float64)
    values -= values.mean()
    # Zero endpoints with short soft fades; looping tracks retain almost all tail.
    attack = round((.008 if loop else .0015) * SR)
    release = round((.008 if loop else .022) * SR)
    values[:attack] *= np.sin(np.linspace(0, np.pi / 2, attack)) ** 2
    values[-release:] *= np.sin(np.linspace(np.pi / 2, 0, release)) ** 2
    values *= peak / max(float(np.max(np.abs(values))), 1e-12)
    pcm = np.rint(values * 32767).astype("<i2")
    path = OUT / (name + ".wav")
    with wave.open(str(path), "wb") as stream:
        stream.setnchannels(1)
        stream.setsampwidth(2)
        stream.setframerate(SR)
        stream.writeframes(pcm.tobytes())
    rms = float(np.sqrt(np.mean(values ** 2)))
    fft = np.fft.rfft(values)
    power = np.abs(fft) ** 2
    frequencies = np.fft.rfftfreq(len(values), 1 / SR)
    centroid = float(np.sum(power * frequencies) / max(np.sum(power), 1e-20))
    high = float(np.sum(power[frequencies > 6000]) / max(np.sum(power), 1e-20))
    record = {"file": name + ".wav", "duration_s": round(len(values) / SR, 3),
        "sample_rate": SR, "channels": 1, "format": "PCM16",
        "peak_dbfs": round(20 * np.log10(max(abs(values).max(), 1e-12)), 2),
        "rms_dbfs": round(20 * np.log10(max(rms, 1e-12)), 2),
        "spectral_energy_centroid_hz": round(centroid, 1),
        "energy_above_6khz_percent": round(high * 100, 4),
        "clipped_samples": int(np.count_nonzero(abs(pcm.astype(np.int32)) >= 32767)),
        "first_sample": int(pcm[0]), "last_sample": int(pcm[-1]),
        "suggest_loop": loop, "description": description}
    assert record["clipped_samples"] == 0
    assert record["first_sample"] == record["last_sample"] == 0
    assert centroid < 3500 and high < .04
    with wave.open(str(path), "rb") as verified:
        assert verified.getnchannels() == 1 and verified.getsampwidth() == 2 and verified.getframerate() == SR
    print(f"{name:16} {record['duration_s']:6.2f}s peak {record['peak_dbfs']:6.2f} dBFS RMS {record['rms_dbfs']:6.2f} dBFS centroid {centroid:7.1f} Hz")
    return record


def main():
    specifications = [
        ("sword_hit", sword_hit, .55, False, "Short iron-on-iron clang with a dry weighty contact"),
        ("arrow_hit", arrow_hit, .40, False, "Fiber-string twang and restrained wooden arrow impact"),
        ("cannon", cannon, .72, False, "Deep pressure blast, low rumble and softened early reflections"),
        ("stone_hit", stone_hit, .62, False, "Heavy stone impact and irregular gravel bounces"),
        ("collapse", collapse, .60, False, "Layered falling masonry, dry beams and settling rubble"),
        ("select", select_sound, .20, False, "Small dry wood-and-metal selection acknowledgement"),
        ("order", order_sound, .23, False, "Two quiet resonant taps acknowledging a command"),
        ("recruit", recruit, .27, False, "Muted gut-string open-fifth recruitment flourish"),
        ("coin", coin, .25, False, "Two restrained small metal coin contacts"),
        ("ambient_wind", ambient_wind, .15, True, "32-second circular low-frequency outdoor wind field"),
        ("ambient_music", ambient_music, .22, True, "Original 32-second sparse gut-string and bowed-low-string phrase"),
    ]
    records = [export(name, make(), peak, loop, description) for name, make, peak, loop, description in specifications]
    report = {"provenance": "Original deterministic numerical synthesis; no external audio or borrowed melody",
              "listening": "Not played through the desktop; validated by PCM, peak, RMS, spectrum and endpoint checks",
              "seed": 849271, "files": records}
    (OUT / "audio_manifest.json").write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    print("AUDIO_VALIDATION_PASSED", len(records), "files; no clipped samples; zero endpoints")


if __name__ == "__main__":
    main()

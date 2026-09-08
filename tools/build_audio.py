"""Offline CC0 foley + original DSP soundbank. No music/ambience is generated.

Dependencies: numpy, scipy, soundfile. Source recordings and licenses are retained
in assets/audio/sources, with Godot imports disabled for this authoring directory.
"""

from pathlib import Path
import hashlib, json, math, wave
import numpy as np
import soundfile as sf
from scipy import signal

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets/audio"
SOURCES = OUT / "sources"
SR = 48000
RNG = np.random.default_rng(849271)
USED = set()
COUNTS = {
    "sword_swing": 3,
    "sword_hit": 4,
    "bow_release": 3,
    "arrow_hit": 3,
    "wood_hit": 3,
    "catapult_release": 2,
    "stone_hit": 3,
    "cannon_shot": 2,
    "explosion": 2,
    "footstep_dirt": 4,
    "horse_hoof": 4,
    "cart_wheel": 3,
    "death_fall": 3,
    "collapse": 2,
    "ui_select": 2,
    "ui_order": 2,
    "ui_recruit": 2,
    "ui_denied": 2,
    "coin": 3,
    "victory": 1,
    "defeat": 1,
}
DESCRIPTIONS = {
    "sword_swing": "Recorded metal scrape under original shaped air swish",
    "sword_hit": "Recorded sword/knife clash with restrained body thump",
    "bow_release": "Original damped string release with recorded arrow feathers and wood",
    "arrow_hit": "Recorded dry wood contact and arrow-feather brush",
    "wood_hit": "Recorded wood and masonry short contact for structures",
    "catapult_release": "Recorded leather creak and plank release with original rope vibration",
    "stone_hit": "Recorded mining/concrete chips with original low impact body",
    "cannon_shot": "Original pressure blast/rumble with recorded metal and wood recoil",
    "explosion": "Original explosive air pressure with recorded scattering stone",
    "footstep_dirt": "Recorded grass/leather footfalls processed into compact dirt steps",
    "horse_hoof": "Designed hoof from recorded wood/concrete steps; not a horse recording",
    "cart_wheel": "Recorded wood knocks and leather creaks",
    "death_fall": "Recorded boot landing, soft body contact and equipment fall; no voice",
    "collapse": "Recorded wood/stone debris over original low dust rumble",
    "ui_select": "Short dry recorded selection click",
    "ui_order": "Recorded toggle and wood acknowledgement",
    "ui_recruit": "Recorded buckle and wooden stamp acknowledgement",
    "ui_denied": "Muted refusal click and dry double wooden knock",
    "coin": "Recorded small metal contacts with original inharmonic coin resonance",
    "victory": "Short struck-metal and flag-rustle signal; no tune",
    "defeat": "Low equipment fall and dull final knock; no tune",
}


def tbase(duration):
    return np.arange(round(duration * SR), dtype=np.float64) / SR


def filt(v, cutoff, mode="lowpass"):
    return signal.sosfilt(signal.butter(3, cutoff, btype=mode, fs=SR, output="sos"), v)


def active_rms(v):
    """20-ms blocks within 20 dB of the maximum block energy; not LUFS."""
    block = 960
    p = np.pad(v, (0, (-len(v)) % block))
    power = np.mean(p.reshape(-1, block) ** 2, axis=1)
    return math.sqrt(
        float(power[power >= max(float(power.max()) * 0.01, 1e-14)].mean())
    )


def noise(duration, band=(80, 2500)):
    v = filt(RNG.standard_normal(round(duration * SR)), band, "bandpass")
    return v / max(float(np.std(v)), 1e-12)


def env(t, attack=0.003, decay=0.14):
    return np.minimum(1.0, t / attack) * np.exp(-t / decay)


def modal(duration, freqs, decay=0.16):
    t = tbase(duration)
    v = np.zeros_like(t)
    for j, f in enumerate(freqs):
        v += (
            np.sin(math.tau * f * t + 0.19 * j)
            * env(t, 0.0012, decay / (1 + j * 0.16))
            / (1 + j * 0.8)
        )
    return v


def mix(duration, layers):
    v = np.zeros(round(duration * SR))
    for sound, at, gain in layers:
        start = round(at * SR)
        count = min(len(sound), len(v) - start)
        if count > 0:
            v[start : start + count] += sound[:count] * gain
    return v


def recorded(pack, name, rate=1.0, duration=None, lowpass=6300):
    relative = pack + "/" + name
    USED.add(relative)
    v, sr = sf.read(SOURCES / relative, dtype="float64", always_2d=True)
    v = v.mean(axis=1)
    divisor = math.gcd(sr, SR)
    v = signal.resample_poly(v, SR // divisor, sr // divisor)
    v -= v.mean()
    v = filt(filt(v, 65, "highpass"), lowpass)
    where = np.flatnonzero(abs(v) > max(abs(v)) * 0.018)
    assert len(where), relative
    v = v[max(0, int(where[0]) - 144) : min(len(v), int(where[-1]) + 1152)]
    if rate != 1.0:
        v = signal.resample_poly(v, 1000, round(1000 * rate))
    if duration is not None:
        v = v[: round(duration * SR)]
    return v / max(active_rms(v), 1e-12)


def imp(name, i, **kw):
    return recorded("kenney_impact", f"{name}_{i%5:03}.ogg", **kw)


def app(name, i, **kw):
    return recorded("weapons_apparel", f"{name}-{i:02}.wav", **kw)


def ui(name, i, **kw):
    return recorded("kenney_interface", f"{name}_{i:03}.ogg", **kw)


def pressure(duration, i, explosion=False):
    t = tbase(duration)
    phase = math.tau * ((38 + i * 3) * t + 74 * 0.075 * (1 - np.exp(-t / 0.075)))
    v = noise(duration, (38, 360)) * env(t, 0.0015, 0.38 if explosion else 0.29)
    v += 0.65 * noise(duration, (90, 1750)) * env(t, 0.0008, 0.085)
    v += 0.11 * noise(duration, (900, 4200)) * env(t, 0.0005, 0.012)
    v += 1.1 * np.sin(phase) * env(t, 0.0012, 0.22)
    v += 0.30 * noise(duration, (32, 190)) * env(t, 0.06, 0.46)
    return v


def make(k, i):
    if k == "sword_swing":
        d = 0.34 + i * 0.025
        t = tbase(d)
        s = noise(d, (350, 4200)) * np.exp(-(((t - 0.085) / 0.055) ** 2))
        return mix(
            d,
            [
                (s, 0, 0.65),
                (
                    app("sword-table-leg-scrape", i, rate=1.3, duration=0.23),
                    0.025,
                    0.10,
                ),
            ],
        )
    if k == "sword_hit":
        return mix(
            0.65,
            [
                (
                    app(
                        "sword-knife-clash",
                        [1, 9, 18, 31][i - 1],
                        rate=[0.91, 1.03, 0.98, 1.12][i - 1],
                    ),
                    0,
                    0.83,
                ),
                (imp("impactMetal_medium", i, duration=0.3), 0.004, 0.18),
                (modal(0.42, [135, 290, 467], 0.09), 0, 0.30),
            ],
        )
    if k == "bow_release":
        t = tbase(0.39)
        phase = math.tau * ((155 + i * 12) * t + 69 * 0.027 * (1 - np.exp(-t / 0.027)))
        string = np.sin(phase) * env(t, 0.0007, 0.048) + 0.32 * modal(
            0.39, [342 + i * 11, 719 + i * 23], 0.038
        )
        return mix(
            0.39,
            [
                (string, 0, 1.3),
                (app("arrow-feathers", i, rate=1.25, duration=0.25), 0, 0.20),
                (imp("impactWood_light", i), 0.005, 0.12),
            ],
        )
    if k == "arrow_hit":
        return mix(
            0.40,
            [
                (imp("impactWood_light", i, rate=0.93 + i * 0.05), 0, 0.9),
                (app("arrow-feathers", i, duration=0.23), 0.008, 0.16),
                (modal(0.26, [142, 360], 0.052), 0, 0.19),
            ],
        )
    if k == "wood_hit":
        return mix(
            0.56,
            [
                (imp("impactWood_heavy", i, rate=0.87 + i * 0.04), 0, 0.84),
                (imp("impactMining", i, lowpass=4200), 0.006, 0.31),
            ],
        )
    if k == "catapult_release":
        return mix(
            0.96,
            [
                (
                    app(
                        "quiver-leather-squeeze",
                        i + 3,
                        rate=0.64,
                        duration=0.6,
                        lowpass=2400,
                    ),
                    0,
                    0.34,
                ),
                (imp("impactPlank_medium", i), 0.035, 0.57),
                (imp("impactWood_heavy", i, rate=0.78), 0.12, 0.48),
                (modal(0.55, [119, 237, 419], 0.12), 0.025, 0.32),
            ],
        )
    if k == "stone_hit":
        layers = [
            (imp("impactMining", i, rate=0.76 + i * 0.05), 0, 0.95),
            (modal(0.7, [69 + i * 5, 138, 263], 0.18), 0, 0.68),
        ]
        for n, at in enumerate([0.09, 0.21, 0.36, 0.57]):
            layers.append(
                (
                    imp("footstep_concrete", i + n, rate=1.1 + n * 0.12, duration=0.22),
                    at,
                    0.22 / (1 + n),
                )
            )
        return mix(1.1, layers)
    if k == "cannon_shot":
        return mix(
            2.15,
            [
                (pressure(2.15, i), 0, 1.0),
                (imp("impactMetal_heavy", i, rate=0.72, lowpass=2800), 0.014, 0.24),
                (imp("impactWood_heavy", i), 0.045, 0.18),
            ],
        )
    if k == "explosion":
        return mix(
            1.85,
            [
                (pressure(1.85, i + 2, True), 0, 1.0),
                (imp("impactMining", i, rate=0.65), 0.03, 0.37),
                (imp("impactMining", i + 2, rate=0.9), 0.22, 0.15),
            ],
        )
    if k == "footstep_dirt":
        return mix(
            0.38,
            [
                (
                    imp("footstep_grass", i - 1, rate=0.96 + i * 0.022, lowpass=4800),
                    0,
                    0.84,
                ),
                (app("boots-leather-step", i, duration=0.3, lowpass=2800), 0, 0.24),
            ],
        )
    if k == "horse_hoof":
        return mix(
            0.40,
            [
                (
                    imp("footstep_wood", i - 1, rate=0.81 + i * 0.025, lowpass=3700),
                    0,
                    0.73,
                ),
                (imp("footstep_concrete", i - 1, rate=0.87, lowpass=4100), 0.023, 0.43),
                (modal(0.25, [114 + i * 4, 225], 0.040), 0, 0.30),
            ],
        )
    if k == "cart_wheel":
        layers = [
            (
                app(
                    "quiver-leather-squeeze",
                    i + 7,
                    rate=0.7,
                    duration=0.72,
                    lowpass=1900,
                ),
                0,
                0.25,
            )
        ]
        for n, at in enumerate([0, 0.23, 0.48]):
            layers.append(
                (
                    imp("impactWood_light", i + n, rate=0.85, lowpass=2800),
                    at,
                    0.36 / (1 + n * 0.15),
                )
            )
        layers.append(
            (imp("impactMetal_light", i, duration=0.2, lowpass=1900), 0.19, 0.045)
        )
        return mix(0.77, layers)
    if k == "death_fall":
        return mix(
            0.85,
            [
                (app("boots-leather-jump", i, rate=0.8, duration=0.65), 0, 0.53),
                (imp("impactSoft_heavy", i, rate=0.8), 0.025, 0.7),
                (
                    imp("impactMetal_medium", i, duration=0.34, lowpass=3200),
                    0.075,
                    0.19,
                ),
                (app("quiver-leather-squeeze", i + 1, duration=0.4), 0.15, 0.16),
            ],
        )
    if k == "collapse":
        d = 2.45
        layers = [(noise(d, (35, 580)) * env(tbase(d), 0.06, 0.53), 0, 0.28)]
        for n, at in enumerate(
            [0, 0.04, 0.10, 0.21, 0.34, 0.50, 0.69, 0.91, 1.17, 1.46, 1.80]
        ):
            layers.append(
                (
                    imp(
                        "impactWood_heavy" if n % 2 == 0 else "impactMining",
                        n + i,
                        rate=0.69 + n * 0.055,
                        lowpass=4600,
                    ),
                    at,
                    0.65 * math.exp(-n * 0.18),
                )
            )
        return mix(d, layers)
    if k == "ui_select":
        return mix(0.18, [(ui("click", i, rate=0.88, lowpass=3700), 0, 1.0)])
    if k == "ui_order":
        return mix(
            0.23,
            [
                (ui("switch", i, rate=0.89, lowpass=3600), 0, 0.8),
                (imp("impactWood_light", i, rate=1.35, lowpass=2500), 0.036, 0.20),
            ],
        )
    if k == "ui_recruit":
        return mix(
            0.45,
            [
                (
                    app("belt-buckle", i, rate=1.16, duration=0.31, lowpass=3900),
                    0,
                    0.46,
                ),
                (imp("impactWood_medium", i, rate=1.2, lowpass=2800), 0.06, 0.77),
                (ui("confirmation", i, duration=0.24, lowpass=2000), 0.07, 0.08),
            ],
        )
    if k == "ui_denied":
        return mix(
            0.31,
            [
                (ui("error", i, rate=0.8, duration=0.25, lowpass=2400), 0, 0.29),
                (imp("impactWood_light", i, rate=0.81, lowpass=1700), 0, 0.54),
                (imp("impactWood_light", i + 1, rate=0.73, lowpass=1500), 0.092, 0.36),
            ],
        )
    if k == "coin":
        return mix(
            0.48,
            [
                (app("belt-buckle", i, rate=1.42, duration=0.3, lowpass=5500), 0, 0.42),
                (imp("impactMetal_light", i, rate=1.7, lowpass=5500), 0.06, 0.24),
                (
                    modal(0.4, [1190 + i * 39, 1860 + i * 61, 2860 + i * 43], 0.057),
                    0,
                    0.49,
                ),
            ],
        )
    if k == "victory":
        return mix(
            1.04,
            [
                (imp("impactBell_heavy", 2, rate=0.92, lowpass=3200), 0, 0.50),
                (
                    app("arrow-feathers", 2, rate=0.57, duration=0.6, lowpass=3200),
                    0.04,
                    0.16,
                ),
                (imp("impactWood_heavy", 1, rate=0.86), 0.015, 0.18),
            ],
        )
    if k == "defeat":
        return mix(
            0.96,
            [
                (imp("impactWood_heavy", 2, rate=0.65, lowpass=1900), 0, 0.73),
                (app("boots-leather-jump", 1, rate=0.67, duration=0.6), 0.03, 0.40),
                (imp("impactMetal_heavy", 3, rate=0.61, lowpass=1800), 0.17, 0.17),
            ],
        )
    raise ValueError(k)


def export(kind, index, v, used):
    target_db = (
        -22.0
        if kind.startswith("ui_") or kind in ("coin", "victory", "defeat")
        else (
            -24.0
            if kind in ("footstep_dirt", "horse_hoof", "cart_wheel")
            else -18.5 if kind in ("cannon_shot", "explosion") else -20.0
        )
    )
    cap_db = -6.0 if target_db <= -22 else -3.0
    cap = 10 ** ((cap_db - 0.25) / 20)
    # Metal recordings remain readable in the 1–5 kHz band. A steeper final
    # rolloff controls bright clash variants before many units are mixed.
    v = filt(v, 38, "highpass")
    if kind == "sword_hit":
        v = signal.sosfilt(
            signal.butter(4, 4800, btype="lowpass", fs=SR, output="sos"), v
        )
    else:
        v = filt(v, 7200)
    v -= v.mean()
    v[:48] *= np.sin(np.linspace(0, np.pi / 2, 48)) ** 2
    v[-1200:] *= np.sin(np.linspace(np.pi / 2, 0, 1200)) ** 2
    target = 10 ** (target_db / 20)
    for _ in range(8):
        v *= target / max(active_rms(v), 1e-12)
        if max(abs(v)) <= cap:
            break
        v = cap * np.tanh(v / cap)
    true_peak = float(max(abs(signal.resample_poly(v, 4, 1))))
    if true_peak > 10 ** (cap_db / 20):
        v *= 10 ** (cap_db / 20) / true_peak
    pcm = np.rint(np.clip(v, -1, 1) * 32767).astype("<i2")
    pcm[0] = pcm[-1] = 0
    decoded = pcm.astype(np.float64) / 32768
    filename = (
        f"{kind}_{index:02}.wav" if kind not in ("victory", "defeat") else kind + ".wav"
    )
    path = OUT / filename
    with wave.open(str(path), "wb") as stream:
        stream.setnchannels(1)
        stream.setsampwidth(2)
        stream.setframerate(SR)
        stream.writeframes(pcm.tobytes())
    db = lambda x: round(20 * math.log10(max(float(x), 1e-12)), 2)
    power = abs(np.fft.rfft(decoded)) ** 2
    freq = np.fft.rfftfreq(len(decoded), 1 / SR)
    measured = db(active_rms(decoded))
    result = {
        "file": filename,
        "kind": kind,
        "variant": index,
        "duration_s": round(len(pcm) / SR, 4),
        "sample_rate": SR,
        "channels": 1,
        "format": "PCM16",
        "peak_dbfs": db(max(abs(decoded))),
        "true_peak_4x_dbtp": db(max(abs(signal.resample_poly(decoded, 4, 1)))),
        "rms_dbfs": db(np.sqrt(np.mean(decoded**2))),
        "active_rms_dbfs": measured,
        "target_active_rms_dbfs": target_db,
        "peak_limit_dbfs": cap_db,
        "energy_above_6khz_percent": round(
            float(power[freq > 6000].sum() / power.sum()) * 100, 3
        ),
        "clipped_samples": int(np.count_nonzero(abs(pcm.astype(np.int32)) >= 32767)),
        "first_sample": int(pcm[0]),
        "last_sample": int(pcm[-1]),
        "source_files": sorted(used),
        "description": DESCRIPTIONS[kind],
        "modifications": "Mono downmix, 48k resample, silence trim, rate adjustment, EQ, foley/DSP layering, endpoint fades, active-RMS gain and soft crest control",
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }
    assert result["clipped_samples"] == 0 and abs(measured - target_db) <= 0.7, result
    assert result["true_peak_4x_dbtp"] <= cap_db + 0.02, result
    print(
        f"{filename:27} {result['duration_s']:4.2f}s active={measured:6.2f} peak={result['peak_dbfs']:6.2f} sources={len(used)}"
    )
    return result


def main():
    global RNG, USED
    OUT.mkdir(exist_ok=True)
    records = []
    for kind, count in COUNTS.items():
        for index in range(1, count + 1):
            RNG = np.random.default_rng(
                int.from_bytes(
                    hashlib.sha256(f"{kind}/{index}".encode()).digest()[:8], "little"
                )
            )
            USED = set()
            values = make(kind, index)
            records.append(export(kind, index, values, USED))
    bank = {kind: [r["file"] for r in records if r["kind"] == kind] for kind in COUNTS}
    (OUT / "soundbank.json").write_text(
        json.dumps(bank, indent=2) + "\n", encoding="utf8"
    )
    report = {
        "format": "48 kHz mono PCM16 WAV",
        "music_included": False,
        "file_count": len(records),
        "provenance": "CC0 recorded foley from Kenney and Vehicle/Jan Schupke, layered with original deterministic DSP; see CREDITS.md and sources.json",
        "active_rms_definition": "20-ms blocks within 20 dB of maximum block energy; not LUFS",
        "listening_validation": "Asset-level technical validation only; no system-loudspeaker playback or perceptual listening claim. Runtime mix verification is recorded separately.",
        "files": records,
    }
    (OUT / "audio_manifest.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf8"
    )
    assert len(records) == 54 and len({r["sha256"] for r in records}) == 54
    print("SFX_BANK_READY: 21 kinds / 54 unique WAV; no music or ambience generated")


if __name__ == "__main__":
    main()

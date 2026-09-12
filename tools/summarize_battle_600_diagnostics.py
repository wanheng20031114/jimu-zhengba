"""Collect release diagnostic evidence without treating ablations as optimizations."""
import argparse
import json
from pathlib import Path
import statistics

from build_battle_600_benchmark import digest


def collect(folder: Path, names: list[str], rejected_names: list[str]) -> dict:
    builds = {}
    for kind in ("profile", "ablation"):
        path = folder / kind / "receipt.json"
        receipt = json.loads(path.read_text(encoding="utf-8"))
        builds[kind] = {key: value for key, value in receipt.items() if key != "base_source_sha256"}
        builds[kind]["receipt_sha256"] = digest(path)
    runs, rejected = [], []
    for name in names + rejected_names:
        path = folder / (name + ".json")
        report = json.loads(path.read_text(encoding="utf-8"))
        environment = json.loads((folder / (name + ".environment.json")).read_text(encoding="utf-8-sig"))
        assert not report["debug_build"] and report["rendered"] and not report["harness_check"]
        if name in rejected_names:
            assert report["failures"], "A rejected run must retain its actual failures"
        else:
            assert not report["failures"] and report["health_multiplier"] == 100
            assert all(p["starting_units"] == p["ending_units"] == 600 and p["damage_events"] > 0
                       and all(m["alive"] == 600 for m in p["monitors"]) for p in report["phases"])
        concurrent = [probe for probe in environment if probe["other_tests"]]
        report["source_result_sha256"] = digest(path)
        report["concurrent_test_observations"] = concurrent
        report["eligible_for_performance_comparison"] = not concurrent and name not in rejected_names
        report["environment_samples"] = len(environment)
        for phase in report["phases"]:
            phase["cached_peak_physics_mean_ms"] = statistics.mean(m["physics_monitor_ms"] for m in phase["monitors"])
            phase["cached_peak_navigation_mean_ms"] = statistics.mean(m["navigation_monitor_ms"] for m in phase["monitors"])
        (rejected if name in rejected_names else runs).append(report)
        p = report["phases"][1]
        print(f"{name:30s} FPS {p['fps']:6.2f}  P95 {p['frame_ms']['p95']:7.2f} ms  TPS {p['tps']:5.2f}  logic {p['physics_logic_ms']['mean']:6.2f} ms  GPU P95 {p['root_render_gpu_ms']['p95']:6.2f} ms  concurrent {len(concurrent)}  failures {len(report['failures'])}")
    return {"schema": 1, "date": "2026-09-13", "builds": builds, "runs": runs, "rejected_runs": rejected,
            "notes": "All entry timers are inclusive and have measurement overhead. Native physics/navigation monitors are cached recent-window maxima; averages of those samples are not average tick costs. Runs with observed concurrent tests are retained but ineligible for performance comparison. Five-second observations cannot exclude shorter unobserved activity. Ablations change behavior and the battle evolves differently, so FPS differences are diagnostic evidence, not controlled production speedups. All tests are offline with bots disabled; online cost remains additional."}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--runs", nargs="+", required=True)
    parser.add_argument("--rejected-runs", nargs="*", default=[])
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = collect(args.directory, args.runs, args.rejected_runs)
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

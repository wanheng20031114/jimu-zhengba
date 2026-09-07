"""Bounded hidden native-window audit with read-only Win32 focus/size sampling."""
import ctypes
from ctypes import wintypes
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
USER32 = ctypes.WinDLL("user32", use_last_error=True)
USER32.GetForegroundWindow.restype = wintypes.HWND
USER32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
USER32.IsWindowVisible.argtypes = [wintypes.HWND]
USER32.GetClientRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
USER32.ClientToScreen.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.POINT)]
ENUM = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
USER32.EnumWindows.argtypes = [ENUM, wintypes.LPARAM]


def process_id(hwnd):
    result = wintypes.DWORD()
    USER32.GetWindowThreadProcessId(hwnd, ctypes.byref(result))
    return result.value


def windows_for(pid):
    matches = []

    @ENUM
    def callback(hwnd, _):
        if process_id(hwnd) == pid:
            area = wintypes.RECT()
            origin = wintypes.POINT()
            USER32.GetClientRect(hwnd, ctypes.byref(area))
            USER32.ClientToScreen(hwnd, ctypes.byref(origin))
            matches.append({"visible": bool(USER32.IsWindowVisible(hwnd)),
                            "client_size": [area.right, area.bottom],
                            "client_origin": [origin.x, origin.y],
                            "foreground": USER32.GetForegroundWindow() == hwnd})
        return True

    USER32.EnumWindows(callback, 0)
    return matches


def run():
    (ROOT / "artifacts/hud_resize").mkdir(parents=True, exist_ok=True)
    startup = subprocess.STARTUPINFO()
    startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = subprocess.SW_HIDE
    with (ROOT / "tests/hud_resize.log").open("w", encoding="utf-8") as output, \
            (ROOT / "tests/hud_resize-errors.log").open("w", encoding="utf-8") as errors:
        process = subprocess.Popen([
            r"C:\Program Files\Godot\Godot.exe", "--path", str(ROOT), "--script",
            "res://tests/hud_resize_test.gd", "--resolution", "1280x720",
            "--position", "10000,10000", "--audio-driver", "Dummy"
        ], cwd=ROOT, startupinfo=startup, creationflags=subprocess.CREATE_NO_WINDOW,
            stdout=output, stderr=errors)
        (ROOT / "tests/hud_resize.pid").write_text(str(process.pid), encoding="utf-8")
        started = time.monotonic()
        samples = []
        previous = None
        try:
            while process.poll() is None:
                if time.monotonic() - started > 65:
                    raise subprocess.TimeoutExpired(process.args, 65)
                windows = windows_for(process.pid)
                if windows and windows != previous:
                    samples.append({"elapsed": round(time.monotonic() - started, 3), "windows": windows})
                    previous = windows
                time.sleep(.1)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(10)
    report_path = ROOT / "artifacts/hud_resize/results.json"
    report = json.loads(report_path.read_text(encoding="utf-8"))
    report["win32_readonly_window_samples"] = samples
    report["win32_observed_foreground_owned_by_test"] = any(
        window["foreground"] for sample in samples for window in sample["windows"])
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"exit": process.returncode, "checks": report["checks"],
                      "failures": report["failures"], "win32_samples": samples}, ensure_ascii=False))
    if process.returncode:
        raise SystemExit(process.returncode)


if __name__ == "__main__":
    run()

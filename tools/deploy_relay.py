"""Deploy only the isolated Ashen Crown relay. Never log connection credentials.

Examples: python tools/deploy_relay.py --certificate
          python tools/deploy_relay.py --deploy
SSH credentials stay in Python memory; the existing UDP 24570 service is untouched.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import re
import shlex
import sys
import time
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
LOCAL = ROOT / ".local" / "network"
KEY = LOCAL / "relay-private.key"
CERT = ROOT / "scripts" / "network" / "relay_trust.crt"
BASE = "/opt/ashen-crown-relay"
SERVICE = "ashen-crown-relay.service"
TLS_NAME = "ashen-crown-relay"
RUNTIME_VERSION = "4.7.2-stable"
RUNTIME_DIGESTS = {
    "linux.x86_64": "cadd3204e728a35d3f13adb7fd0d7902636b79f6b95c40c265eb73b6c35329e4",
    "win64.exe": "731980f9608d61333e5baf54a2ef17210acc7a538446c0cb9969f002aca1e953",
}


def relay_journal_ready(journal: str) -> bool:
    """A rejected DTLS peer does not invalidate an otherwise healthy relay host."""
    ready = False
    for raw in journal.splitlines():
        line = raw.strip()
        if re.fullmatch(r"ERROR: D?TLS handshake error: -[1-9][0-9]*", line):
            continue
        if "SCRIPT ERROR" in line or "ERROR:" in line or "RELAY_TRANSPORT_ERROR" in line:
            raise RuntimeError("The new relay did not start cleanly")
        if re.fullmatch(r"ASHEN_RELAY_READY protocol=[0-9]+ rooms=[0-9]+ humans=[0-9]+", line):
            ready = True
    return ready


def relay_service_identity(output: str, expected: tuple[str, int, int] | None = None) -> tuple[str, int, int]:
    """Read the native systemd identity and reject exits or restarts during readiness."""
    properties = dict(line.split("=", 1) for line in output.splitlines() if "=" in line)
    invocation = properties.get("InvocationID", "")
    pid = properties.get("MainPID", "")
    restarts = properties.get("NRestarts", "")
    if (not re.fullmatch(r"[0-9a-f]{32}", invocation) or not pid.isdigit() or int(pid) <= 0
            or not restarts.isdigit() or properties.get("ActiveState") != "active"
            or properties.get("SubState") != "running"):
        raise RuntimeError("The relay service is not running with a verifiable identity")
    identity = (invocation, int(pid), int(restarts))
    if expected is not None and identity != expected:
        raise RuntimeError("The relay service changed identity or restarted during readiness")
    return identity


def runtime(platform: str = "linux.x86_64") -> Path:
    """Pin the official runtime containing Godot's DTLS cookie cleanup fix."""
    name = "Godot_v" + RUNTIME_VERSION + "_" + platform
    folder = LOCAL / "runtime"
    folder.mkdir(parents=True, exist_ok=True)
    archive = folder / (name + ".zip")
    expected = RUNTIME_DIGESTS[platform]
    if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
        url = "https://github.com/godotengine/godot-builds/releases/download/" + RUNTIME_VERSION + "/" + archive.name
        with urllib.request.urlopen(url, timeout=45) as source, archive.open("wb") as output:
            while block := source.read(1024 * 1024):
                output.write(block)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
            raise RuntimeError("Official runtime archive checksum mismatch")
    executable = folder / name
    with zipfile.ZipFile(archive) as zipped:
        binary = zipped.read(name)
        if not executable.exists() or hashlib.sha256(executable.read_bytes()).digest() != hashlib.sha256(binary).digest():
            executable.write_bytes(binary)
        console = name.replace(".exe", "_console.exe")
        if platform == "win64.exe" and console in zipped.namelist():
            console_file = folder / console
            console_binary = zipped.read(console)
            if not console_file.exists() or console_file.read_bytes() != console_binary:
                console_file.write_bytes(console_binary)
    return executable


def certificate() -> None:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

    if KEY.exists() and CERT.exists():
        private = serialization.load_pem_private_key(KEY.read_bytes(), password=None)
        cert = x509.load_pem_x509_certificate(CERT.read_bytes())
        if private.public_key().public_numbers() != cert.public_key().public_numbers():
            raise RuntimeError("Existing private key and public certificate do not match")
        return
    if KEY.exists() or CERT.exists():
        raise RuntimeError("Refusing to replace an incomplete existing certificate pair")
    LOCAL.mkdir(parents=True, exist_ok=True)
    private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    now = dt.datetime.now(dt.timezone.utc)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, TLS_NAME)])
    public = (
        x509.CertificateBuilder()
        .subject_name(name).issuer_name(name).public_key(private.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - dt.timedelta(days=1))
        .not_valid_after(now + dt.timedelta(days=1095))
        .add_extension(x509.SubjectAlternativeName([x509.DNSName(TLS_NAME)]), critical=False)
        .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
        .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
        .sign(private, hashes.SHA256())
    )
    KEY.write_bytes(private.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption()))
    CERT.write_bytes(public.public_bytes(serialization.Encoding.PEM))


def credentials() -> dict[str, str]:
    entries: list[dict[str, str]] = []
    current = None
    for raw in Path(r"C:/Users/wh/Downloads/.env").read_text(encoding="utf-8-sig").splitlines():
        text = raw.strip()
        if not text or text.startswith("#") or "=" not in text:
            continue
        key, value = text.split("=", 1)
        key = key.strip().lower().removeprefix("export ")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        if key == "server_name":
            current = {key: value}
            entries.append(current)
        elif current is not None:
            current[key] = value
    matches = [entry for entry in entries if entry.get("server_name", "").lower() == "shanghai"]
    if len(matches) != 1 or not all(matches[0].get(key) for key in ("ip", "username", "password")):
        raise RuntimeError("The shanghai credential block is incomplete or ambiguous")
    return matches[0]


def deploy() -> None:
    import paramiko

    certificate()
    config = credentials()
    executable = runtime()
    executable_digest = hashlib.sha256(executable.read_bytes()).hexdigest()
    runtime_path = BASE + "/bin/godot-" + executable_digest[:16]
    payload = {
        "project.godot": (ROOT / "server" / "relay_project.godot").read_bytes(),
        "scripts/network/network_protocol.gd": (ROOT / "scripts/network/network_protocol.gd").read_bytes(),
        "server/relay_server.gd": (ROOT / "server/relay_server.gd").read_bytes(),
        "server/relay_main.gd": (ROOT / "server/relay_main.gd").read_bytes(),
        "server/relay.tscn": (ROOT / "server/relay.tscn").read_bytes(),
    }
    manifest = ROOT / "data/content_manifest.json"
    if manifest.exists():
        payload["data/content_manifest.json"] = manifest.read_bytes()
    digest = hashlib.sha256(b"".join(path.encode() + payload[path] for path in sorted(payload))).hexdigest()[:16]
    release = f"{BASE}/releases/{digest}"
    ssh = paramiko.SSHClient()
    # Only add this explicitly supplied deployment host in memory; no known-host mutation.
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    def run(command: str, timeout: int = 30) -> str:
        stdin, stdout, stderr = ssh.exec_command(command, timeout=timeout)
        stdin.close()
        output = stdout.read().decode("utf-8", "replace")
        stderr.read()  # Raw daemon diagnostics may contain addresses; never echo them.
        if stdout.channel.recv_exit_status() != 0:
            raise RuntimeError("A bounded remote deployment operation failed")
        return output.strip()

    def upload(sftp, path: str, data: bytes, mode: int = 0o644) -> None:
        if not path.startswith(BASE + "/"):
            raise RuntimeError("Deployment path escaped the isolated relay directory")
        run("install -d -m 755 " + shlex.quote(path.rsplit("/", 1)[0]))
        with sftp.open(path, "wb") as handle:
            sftp.chmod(path, mode)
            handle.write(data)

    try:
        ssh.connect(config["ip"], port=int(config.get("port", "22")), username=config["username"], password=config["password"], timeout=12, banner_timeout=12, auth_timeout=12, allow_agent=False, look_for_keys=False)
        if run("id -u") != "0":
            raise RuntimeError("This isolated systemd deployment requires the authorized administrative account")
        # Snapshot the unrelated application's identity so deployment can verify preservation.
        old_pid = run("systemctl show bot-jump-relay.service -p MainPID --value")
        if not old_pid.isdigit() or int(old_pid) <= 0:
            raise RuntimeError("Existing relay was not in the expected running state")
        run("install -d -m 755 " + shlex.quote(BASE) + " " + shlex.quote(BASE + "/bin") + " " + shlex.quote(BASE + "/config"))
        run("id -u ashencrown >/dev/null 2>&1 || useradd --system --home-dir " + shlex.quote(BASE) + " --shell /usr/sbin/nologin ashencrown")
        with ssh.open_sftp() as sftp:
            present = run("if [ -f " + shlex.quote(runtime_path) + " ]; then sha256sum " + shlex.quote(runtime_path) + "; fi")
            if not present.startswith(executable_digest):
                upload(sftp, runtime_path, executable.read_bytes(), 0o755)
            for path, content in payload.items():
                upload(sftp, release + "/" + path, content)
            upload(sftp, BASE + "/config/relay-private.key", KEY.read_bytes(), 0o600)
            upload(sftp, BASE + "/config/relay.crt", CERT.read_bytes())
            relay_config = '[relay]\nbind="*"\nport=24571\nmax_rooms=1\nmax_humans=6\n\n[tls]\nprivate_key="' + BASE + '/config/relay-private.key"\ncertificate="' + BASE + '/config/relay.crt"\n'
            upload(sftp, BASE + "/config/relay.cfg", relay_config.encode(), 0o600)
            unit = f"""[Unit]
Description=Ashen Crown encrypted match relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ashencrown
Group=ashencrown
WorkingDirectory={BASE}/current
Environment=ASHEN_RELAY_CONFIG={BASE}/config/relay.cfg
Environment=HOME={BASE}/state
ExecStart={runtime_path} --headless --path {BASE}/current --script res://server/relay_main.gd
Restart=on-failure
RestartSec=3
TimeoutStopSec=10
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths={BASE}/state {BASE}/releases
MemoryMax=384M
TasksMax=48
LimitNOFILE=1024

[Install]
WantedBy=multi-user.target
"""
            upload(sftp, BASE + "/config/" + SERVICE, unit.encode())
        run("install -d -m 750 -o ashencrown -g ashencrown " + shlex.quote(BASE + "/state"))
        run("chown -R ashencrown:ashencrown " + shlex.quote(release) + " " + shlex.quote(BASE + "/config"))
        run("ln -sfn " + shlex.quote(release) + " " + shlex.quote(BASE + "/current"))
        run("install -m 644 " + shlex.quote(BASE + "/config/" + SERVICE) + " /etc/systemd/system/" + SERVICE)
        run("systemctl daemon-reload")
        run("systemctl enable " + SERVICE)
        run("systemctl restart " + SERVICE)
        # Require readiness from this invocation, not a stale journal entry.
        identity_command = "systemctl show " + SERVICE + " -p InvocationID -p MainPID -p ActiveState -p SubState -p NRestarts"
        identity = relay_service_identity(run(identity_command))
        invocation = identity[0]
        deadline = time.monotonic() + 8
        ready = False
        while time.monotonic() < deadline:
            journal = run("journalctl _SYSTEMD_INVOCATION_ID=" + invocation + " --no-pager -o cat")
            if relay_journal_ready(journal):
                ready = True
                break
            time.sleep(0.25)
        if not ready:
            raise RuntimeError("The new relay did not report readiness")
        relay_service_identity(run(identity_command), identity)
        after_pid = run("systemctl show bot-jump-relay.service -p MainPID --value")
        if old_pid != after_pid:
            raise RuntimeError("Service verification or preservation of the existing relay failed")
        # Connection endpoint is local-only; never commit or echo the credential source.
        LOCAL.mkdir(parents=True, exist_ok=True)
        (LOCAL / "endpoint.json").write_text(json.dumps({"server_name": "shanghai", "address": config["ip"], "port": 24571}), encoding="utf-8")
        print(json.dumps({"server_name": "shanghai", "service": SERVICE, "state": "active", "release": digest, "existing_relay_preserved": True}))
    finally:
        ssh.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--certificate", action="store_true")
    action.add_argument("--deploy", action="store_true")
    action.add_argument("--runtimes", action="store_true")
    args = parser.parse_args()
    try:
        if args.certificate:
            certificate()
            print("RELAY_CERTIFICATE_READY public certificate tracked; private key stays local")
        elif args.runtimes:
            runtime("win64.exe")
            runtime("linux.x86_64")
            print("RELAY_RUNTIMES_VERIFIED version=" + RUNTIME_VERSION)
        else:
            deploy()
        return 0
    except Exception as error:
        # In particular, Paramiko exception strings can contain host addresses.
        print("RELAY_OPERATION_FAILED type=" + type(error).__name__, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

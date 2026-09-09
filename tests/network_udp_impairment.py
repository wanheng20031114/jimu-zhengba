"""Seeded UDP impairment for integration tests; DTLS bytes remain opaque.

One listener per test peer, one upstream socket per source flow (including a
reconnect). No OS network setting, server configuration, or packet is rewritten.
"""
from __future__ import annotations

import heapq
import random
import selectors
import socket
import threading
import time


class ImpairedRelay:
    def __init__(self, upstream: tuple[str, int], peers: int = 4, seed: int = 24571,
                 rtt_ms: float = 150, rtt_jitter_ms: float = 40,
                 loss: float = 0.04, reorder: float = 0.08):
        self.upstream = upstream
        self.profile = {"seed": seed, "link_rtt_ms": rtt_ms,
                        "link_rtt_jitter_bound_ms": rtt_jitter_ms,
                        "datagram_loss_probability": loss,
                        "extra_reorder_probability": reorder,
                        "extra_reorder_delay_ms": 90}
        self.random = random.Random(seed)
        self.selector = selectors.DefaultSelector()
        self.listeners: list[socket.socket] = []
        self.flows: dict[tuple, dict] = {}
        self.pending: list[tuple] = []
        self.stats: dict[tuple, dict] = {}
        self.stop_event = threading.Event()
        self.thread: threading.Thread | None = None
        self.serial = 0
        self.error: str | None = None
        for index in range(peers):
            listener = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            listener.bind(("127.0.0.1", 0))
            listener.setblocking(False)
            self.listeners.append(listener)
            self.selector.register(listener, selectors.EVENT_READ, ("client", index, None))
        self.ports = [listener.getsockname()[1] for listener in self.listeners]

    def start(self) -> "ImpairedRelay":
        self.thread = threading.Thread(target=self._run, name="test-udp-impairment", daemon=True)
        self.thread.start()
        return self

    def close(self) -> dict:
        self.stop_event.set()
        if self.thread is not None:
            self.thread.join(timeout=3)
            if self.thread.is_alive():
                raise RuntimeError("udp_impairment_thread_did_not_stop")
            self.thread = None
        abandoned = len(self.pending)
        self.pending.clear()
        for key in list(self.selector.get_map().values()):
            self.selector.unregister(key.fileobj)
            key.fileobj.close()
        self.selector.close()
        records = []
        for (peer, direction), original in sorted(self.stats.items()):
            record = {key: value for key, value in original.items() if key not in ("last_delivered", "delay_sum_ms")}
            record.update(peer=peer, direction=direction)
            record["actual_loss_percent"] = round(record["dropped"] * 100 / max(1, record["received"]), 3)
            record["mean_delivered_delay_ms"] = round(original["delay_sum_ms"] / max(1, record["delivered"]), 3)
            records.append(record)
        totals = {key: sum(record[key] for record in records) for key in (
            "received", "bytes", "dropped", "delivered", "reorder_injected", "out_of_order_deliveries")}
        totals["actual_loss_percent"] = round(totals["dropped"] * 100 / max(1, totals["received"]), 3)
        return {"profile": self.profile, "flows": len(self.flows), "totals": totals, "directions": records,
                "pending_discarded_at_cleanup": abandoned, "error": self.error}

    def _flow(self, peer: int, client: tuple) -> dict:
        key = (peer, client)
        if key not in self.flows:
            upstream = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            upstream.connect(self.upstream)
            upstream.setblocking(False)
            flow = {"socket": upstream, "client": client, "peer": peer}
            self.flows[key] = flow
            self.selector.register(upstream, selectors.EVENT_READ, ("server", peer, flow))
        return self.flows[key]

    def _schedule(self, peer: int, direction: str, packet: bytes,
                  target: socket.socket, address: tuple | None) -> None:
        record = self.stats.setdefault((peer, direction), {
            "received": 0, "bytes": 0, "dropped": 0, "delivered": 0,
            "reorder_injected": 0, "out_of_order_deliveries": 0,
            "last_delivered": 0, "delay_sum_ms": 0.0, "max_delivered_delay_ms": 0.0,
            "closed_flow_errors": 0})
        record["received"] += 1
        record["bytes"] += len(packet)
        if self.random.random() < self.profile["datagram_loss_probability"]:
            record["dropped"] += 1
            return
        delay = self.profile["link_rtt_ms"] / 2 + self.random.uniform(
            -self.profile["link_rtt_jitter_bound_ms"] / 2,
            self.profile["link_rtt_jitter_bound_ms"] / 2)
        if self.random.random() < self.profile["extra_reorder_probability"]:
            delay += self.profile["extra_reorder_delay_ms"]
            record["reorder_injected"] += 1
        self.serial += 1
        now = time.monotonic()
        heapq.heappush(self.pending, (now + delay / 1000, self.serial, now,
                                    record["received"], record, packet, target, address))

    def _deliver(self, now: float) -> None:
        while self.pending and self.pending[0][0] <= now:
            _, _, received_at, sequence, record, packet, target, address = heapq.heappop(self.pending)
            try:
                if address is None:
                    target.send(packet)
                else:
                    target.sendto(packet, address)
            except (ConnectionResetError, ConnectionRefusedError):
                # Old ENet flows intentionally die during reconnect tests. An
                # ICMP refusal belongs to that flow and must not reach a new one.
                record["closed_flow_errors"] += 1
                continue
            record["delivered"] += 1
            delay_ms = (now - received_at) * 1000
            record["delay_sum_ms"] += delay_ms
            record["max_delivered_delay_ms"] = max(record["max_delivered_delay_ms"], round(delay_ms, 3))
            if sequence < record["last_delivered"]:
                record["out_of_order_deliveries"] += 1
            record["last_delivered"] = max(sequence, record["last_delivered"])

    def _run(self) -> None:
        try:
            while not self.stop_event.is_set():
                now = time.monotonic()
                self._deliver(now)
                timeout = min(0.01, max(0.0, self.pending[0][0] - now)) if self.pending else 0.01
                for key, _ in self.selector.select(timeout):
                    direction, peer, flow = key.data
                    for _ in range(64):
                        try:
                            packet, address = key.fileobj.recvfrom(65535)
                        except BlockingIOError:
                            break
                        except (ConnectionResetError, ConnectionRefusedError):
                            break
                        if direction == "client":
                            flow = self._flow(peer, address)
                            self._schedule(peer, "client_to_relay", packet, flow["socket"], None)
                        else:
                            self._schedule(peer, "relay_to_client", packet, self.listeners[peer], flow["client"])
        except Exception as error:
            # Socket diagnostics can contain endpoints; reports contain only a type.
            self.error = type(error).__name__
            self.stop_event.set()

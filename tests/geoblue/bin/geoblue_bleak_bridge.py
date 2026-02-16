#!/usr/bin/env python3
"""
GeoBlue bleak bridge for Linux CLI tests.

Protocol over stdin/stdout (NDJSON):
  request: {"cmd":"scan","request_id":"1",...}
  reply:   {"reply_to":"scan","request_id":"1","ok":true,...}
  event:   {"event":"frame","frame":{...}}
"""

import asyncio
import json
import os
import sys
from typing import Any, Dict, Optional

try:
    from bleak import BleakClient, BleakScanner
except Exception as exc:  # pragma: no cover
    sys.stderr.write(f"bleak import failed: {exc}\n")
    sys.stderr.flush()
    raise

SERVICE_UUID_HINT = "0000ffe0-0000-1000-8000-00805f9b34fb"
WRITE_UUID_HINT = "fff1"
NOTIFY_UUID_HINT = "fff2"
DEBUG = os.environ.get("GEOBLUE_BRIDGE_DEBUG") == "1"


class BridgeState:
    def __init__(self) -> None:
        self.client: Optional[BleakClient] = None
        self.write_uuid: Optional[str] = None
        self.notify_uuid: Optional[str] = None
        self.rx_text = ""


STATE = BridgeState()


def emit(payload: Dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def reply(cmd: str, request_id: str, ok: bool, **kwargs: Any) -> None:
    payload = {
        "reply_to": cmd,
        "request_id": request_id,
        "ok": ok,
    }
    payload.update(kwargs)
    emit(payload)


def normalize_uuid(value: Optional[str]) -> str:
    return (value or "").lower()


def on_notify(_sender: Any, data: bytearray) -> None:
    try:
        raw = bytes(data)
        if not raw:
            return
        if DEBUG:
            sys.stderr.write(f"notify chunk {len(raw)} bytes\n")
            sys.stderr.flush()
        STATE.rx_text += raw.decode("utf-8", errors="ignore")
        decoder = json.JSONDecoder()

        while True:
            try:
                start = STATE.rx_text.find("{")
                if start < 0:
                    STATE.rx_text = ""
                    return
                if start > 0:
                    STATE.rx_text = STATE.rx_text[start:]

                frame, consumed = decoder.raw_decode(STATE.rx_text)
                if isinstance(frame, dict):
                    emit({"event": "frame", "frame": frame})
                STATE.rx_text = STATE.rx_text[consumed:]
            except Exception as exc:
                # Incomplete JSON is expected until enough chunks arrive.
                if DEBUG:
                    preview = STATE.rx_text[:120]
                    sys.stderr.write(
                        f"notify decode pending/error: {type(exc).__name__}: {exc}; len={len(STATE.rx_text)} preview={preview}\n"
                    )
                    sys.stderr.flush()
                return
    except Exception as exc:
        sys.stderr.write(f"on_notify error: {exc}\n")
        sys.stderr.flush()


async def cmd_scan(request_id: str, req: Dict[str, Any]) -> None:
    timeout = float(req.get("timeout", 8.0))

    devices = []

    discovered = await BleakScanner.discover(timeout=timeout, return_adv=True)

    for address, item in discovered.items():
        device, adv = item
        uuids = [normalize_uuid(u) for u in (adv.service_uuids or [])]

        is_geogram = any("ffe0" in u for u in uuids)

        if not is_geogram:
            md = adv.manufacturer_data or {}
            for _cid, raw in md.items():
                if raw and len(raw) >= 1 and raw[0] == 0x3E:
                    is_geogram = True
                    break

        if not is_geogram and device.name:
            is_geogram = "geogram" in device.name.lower()

        if not is_geogram:
            continue

        devices.append(
            {
                "address": address,
                "name": device.name,
                "rssi": adv.rssi,
                "service_uuids": uuids,
            }
        )

    reply("scan", request_id, True, devices=devices)


async def disconnect_internal() -> None:
    if STATE.client is None:
        return

    try:
        if STATE.notify_uuid:
            await STATE.client.stop_notify(STATE.notify_uuid)
    except Exception:
        pass

    try:
        await STATE.client.disconnect()
    except Exception:
        pass

    STATE.client = None
    STATE.write_uuid = None
    STATE.notify_uuid = None
    STATE.rx_text = ""


async def cmd_connect(request_id: str, req: Dict[str, Any]) -> None:
    address = req.get("address")
    if not address:
        reply("connect", request_id, False, error="missing address")
        return

    await disconnect_internal()

    client = BleakClient(str(address))
    await client.connect(timeout=15.0)

    services = None
    if hasattr(client, "get_services"):
        services = await client.get_services()
    else:
        services = getattr(client, "services", None)

    if services is None:
        await client.disconnect()
        reply("connect", request_id, False, error="could not resolve GATT services")
        return

    write_uuid = None
    notify_uuid = None

    for service in services:
        for ch in service.characteristics:
            luuid = normalize_uuid(ch.uuid)
            if WRITE_UUID_HINT in luuid and write_uuid is None:
                write_uuid = ch.uuid
            if NOTIFY_UUID_HINT in luuid and notify_uuid is None:
                notify_uuid = ch.uuid

    if write_uuid is None or notify_uuid is None:
        await client.disconnect()
        reply("connect", request_id, False, error="required GATT characteristics not found")
        return

    await client.start_notify(notify_uuid, on_notify)

    STATE.client = client
    STATE.write_uuid = write_uuid
    STATE.notify_uuid = notify_uuid

    reply(
        "connect",
        request_id,
        True,
        address=address,
        write_uuid=write_uuid,
        notify_uuid=notify_uuid,
        service_hint=SERVICE_UUID_HINT,
    )


async def cmd_send(request_id: str, req: Dict[str, Any]) -> None:
    if STATE.client is None or not STATE.client.is_connected:
        reply("send", request_id, False, error="not connected")
        return

    if not STATE.write_uuid:
        reply("send", request_id, False, error="write characteristic not available")
        return

    frame = req.get("frame")
    if not isinstance(frame, dict):
        reply("send", request_id, False, error="missing frame object")
        return

    payload = json.dumps(frame, separators=(",", ":")).encode("utf-8")

    chunk_size = int(req.get("chunk_size", 160))
    if chunk_size < 20:
        chunk_size = 20
    mtu_size = getattr(STATE.client, "mtu_size", 23)
    mtu_chunk = max(20, int(mtu_size) - 3)
    if chunk_size > mtu_chunk:
        chunk_size = mtu_chunk

    for i in range(0, len(payload), chunk_size):
        chunk = payload[i : i + chunk_size]
        await STATE.client.write_gatt_char(STATE.write_uuid, chunk, response=False)
        await asyncio.sleep(0.03)

    reply("send", request_id, True, bytes=len(payload))


async def cmd_disconnect(request_id: str, _req: Dict[str, Any]) -> None:
    await disconnect_internal()
    reply("disconnect", request_id, True)


async def cmd_stop(request_id: str, _req: Dict[str, Any]) -> None:
    await disconnect_internal()
    reply("stop", request_id, True)
    raise SystemExit(0)


async def handle_command(req: Dict[str, Any]) -> None:
    cmd = req.get("cmd")
    request_id = str(req.get("request_id", "0"))

    try:
        if cmd == "scan":
            await cmd_scan(request_id, req)
        elif cmd == "connect":
            await cmd_connect(request_id, req)
        elif cmd == "send":
            await cmd_send(request_id, req)
        elif cmd == "disconnect":
            await cmd_disconnect(request_id, req)
        elif cmd == "stop":
            await cmd_stop(request_id, req)
        else:
            reply(str(cmd), request_id, False, error=f"unknown command: {cmd}")
    except Exception as exc:
        reply(str(cmd), request_id, False, error=str(exc))


async def read_stdin_loop() -> None:
    while True:
        line = await asyncio.to_thread(sys.stdin.readline)
        if line == "":
            break
        line = line.strip()
        if not line:
            continue

        try:
            req = json.loads(line)
            if not isinstance(req, dict):
                continue
        except Exception:
            continue

        await handle_command(req)


async def main() -> int:
    await read_stdin_loop()
    await disconnect_internal()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(asyncio.run(main()))
    except KeyboardInterrupt:
        raise SystemExit(130)

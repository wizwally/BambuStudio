#!/usr/bin/env python3
"""Fake Bambu Lab P1S for testing the app's LAN status monitor without a printer.

Speaks just enough MQTT 3.1.1 over TLS (port 8883, self-signed certificate,
user "bblp" + access code) and behaves like a P1 series printer: a full report
after "pushall", then incremental reports (only changed fields) every second.

    python3 ios/tools/fake_printer.py [--port 8883] [--serial 01P00TEST000001] [--code 12345678]

The iPad Simulator reaches it at 127.0.0.1. Needs only the Python standard
library and the openssl command (to create the certificate).
"""
import argparse
import json
import os
import socket
import ssl
import subprocess
import tempfile
import threading
import time


def make_certificate(directory, serial):
    cert, key = os.path.join(directory, "cert.pem"), os.path.join(directory, "key.pem")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key,
                    "-out", cert, "-days", "2", "-subj", f"/CN={serial}"],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return cert, key


def encode_length(n):
    out = bytearray()
    while True:
        byte, n = n % 128, n // 128
        out.append(byte | (0x80 if n else 0))
        if not n:
            return bytes(out)


def mqtt_string(s):
    b = s.encode()
    return len(b).to_bytes(2, "big") + b


def read_exact(sock, n):
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise ConnectionError("closed")
        data += chunk
    return data


def read_packet(sock):
    header = read_exact(sock, 1)[0]
    length, multiplier = 0, 1
    while True:
        byte = read_exact(sock, 1)[0]
        length += (byte & 0x7F) * multiplier
        if not byte & 0x80:
            break
        multiplier *= 128
    return header, read_exact(sock, length) if length else b""


def publish_packet(topic, payload):
    body = mqtt_string(topic) + payload
    return bytes([0x30]) + encode_length(len(body)) + body


FULL_REPORT = {
    "print": {
        "command": "push_status", "msg": 0, "sequence_id": "1",
        "gcode_state": "RUNNING", "subtask_name": "3DBenchy", "gcode_file": "3DBenchy.gcode.3mf",
        "mc_percent": 37, "mc_remaining_time": 42, "layer_num": 88, "total_layer_num": 240,
        "nozzle_temper": 219.8, "nozzle_target_temper": 220.0,
        "bed_temper": 54.9, "bed_target_temper": 55.0, "chamber_temper": 5.0,
        "cooling_fan_speed": "15", "big_fan1_speed": "10", "big_fan2_speed": "0",
        "spd_lvl": 2, "wifi_signal": "-48dBm", "print_error": 0, "hms": [],
        "lights_report": [{"node": "chamber_light", "mode": "on"}],
        "ams": {
            "tray_now": "1",
            "ams": [{"id": "0", "humidity": "4", "temp": "25.1", "tray": [
                {"id": "0", "tray_type": "PLA", "tray_color": "00AE42FF", "remain": 80},
                {"id": "1", "tray_type": "PLA", "tray_color": "FFFFFFFF", "remain": 55},
                {"id": "2", "tray_type": "PETG", "tray_color": "161616FF", "remain": 100},
                {"id": "3"},
            ]}],
        },
        "vt_tray": {"id": "254", "tray_type": "", "tray_color": "00000000"},
    }
}

VERSION_REPLY = {"info": {"command": "get_version", "sequence_id": "1", "module": [
    {"name": "ota", "sw_ver": "01.09.00.00 (fake)"}, {"name": "mc", "sw_ver": "00.00.00.00"}]}}


def serve_client(conn, serial, code, verbose):
    report_topic = f"device/{serial}/report"
    lock = threading.Lock()
    running = True
    state = {"percent": 37, "layer": 88, "remaining": 42}

    def send(data):
        with lock:
            conn.sendall(data)

    def pusher():
        tick = 0
        while running:
            time.sleep(1)
            tick += 1
            state["percent"] = min(100, state["percent"] + 1)
            state["layer"] = min(240, state["layer"] + 2)
            state["remaining"] = max(0, state["remaining"] - 1)
            delta = {"print": {"command": "push_status", "msg": 1, "sequence_id": str(tick + 1),
                               "mc_percent": state["percent"], "layer_num": state["layer"],
                               "mc_remaining_time": state["remaining"],
                               "nozzle_temper": 219.5 + (tick % 3) * 0.2}}
            try:
                send(publish_packet(report_topic, json.dumps(delta).encode()))
            except OSError:
                return

    subscribed = False
    try:
        while True:
            header, body = read_packet(conn)
            kind = header >> 4
            if kind == 1:  # CONNECT
                i = 2 + int.from_bytes(body[0:2], "big") + 1  # protocol name + level
                flags = body[i]
                i += 3  # flags + keep alive
                fields = []
                while i < len(body):
                    n = int.from_bytes(body[i:i + 2], "big")
                    fields.append(body[i + 2:i + 2 + n].decode())
                    i += 2 + n
                client_id = fields[0]
                user = fields[1] if flags & 0x80 and len(fields) > 1 else ""
                password = fields[2] if flags & 0x40 and len(fields) > 2 else ""
                ok = user == "bblp" and password == code
                print(f"CONNECT client={client_id} user={user} {'OK' if ok else 'RIFIUTATO'}", flush=True)
                send(bytes([0x20, 2, 0, 0 if ok else 4]))
                if not ok:
                    return
            elif kind == 8:  # SUBSCRIBE
                pid = body[0:2]
                n = int.from_bytes(body[2:4], "big")
                topic = body[4:4 + n].decode()
                print(f"SUBSCRIBE {topic}", flush=True)
                send(bytes([0x90, 3]) + pid + bytes([0 if topic == report_topic else 0x80]))
                if topic == report_topic and not subscribed:
                    subscribed = True
                    threading.Thread(target=pusher, daemon=True).start()
            elif kind == 3:  # PUBLISH from the app
                n = int.from_bytes(body[0:2], "big")
                topic, payload = body[2:2 + n].decode(), body[2 + n:]
                print(f"PUBLISH {topic} {payload.decode(errors='replace')}", flush=True)
                try:
                    msg = json.loads(payload)
                except ValueError:
                    continue
                if msg.get("pushing", {}).get("command") == "pushall":
                    full = json.loads(json.dumps(FULL_REPORT))
                    full["print"].update(mc_percent=state["percent"], layer_num=state["layer"],
                                         mc_remaining_time=state["remaining"])
                    send(publish_packet(report_topic, json.dumps(full).encode()))
                elif msg.get("info", {}).get("command") == "get_version":
                    send(publish_packet(report_topic, json.dumps(VERSION_REPLY).encode()))
            elif kind == 12:  # PINGREQ
                send(bytes([0xD0, 0]))
            elif kind == 14:  # DISCONNECT
                print("DISCONNECT", flush=True)
                return
            elif verbose:
                print(f"packet type {kind} ignorato", flush=True)
    except (ConnectionError, OSError, ssl.SSLError):
        pass
    finally:
        running = False
        conn.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8883)
    ap.add_argument("--serial", default="01P00TEST000001")
    ap.add_argument("--code", default="12345678")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    directory = tempfile.mkdtemp(prefix="fake_printer_")
    cert, key = make_certificate(directory, args.serial)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.host, args.port))
    server.listen(4)
    print(f"Stampante finta su {args.host}:{args.port} serial={args.serial} codice={args.code}", flush=True)
    while True:
        raw, addr = server.accept()
        try:
            conn = context.wrap_socket(raw, server_side=True)
        except (ssl.SSLError, OSError) as e:
            print(f"TLS fallito da {addr[0]}: {e}", flush=True)
            raw.close()
            continue
        threading.Thread(target=serve_client, args=(conn, args.serial, args.code, args.verbose),
                         daemon=True).start()


if __name__ == "__main__":
    main()

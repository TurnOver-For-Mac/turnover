#!/usr/bin/env python3
"""Fallback listener that needs nothing compiled: speaks with the Mac's `say`
command. Same line protocol as d4bridge.swift (S <text> / X) on 127.0.0.1:52134.
Each new line cuts the previous one off. Use this for the very first words out
of the game; the Swift listener is the one that talks to VoiceOver."""
import socket, subprocess, sys, time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 52134
current = None

def stop():
    global current
    if current and current.poll() is None:
        current.kill()
    current = None

def say(text):
    global current
    stop()
    current = subprocess.Popen(["say", "--", text])

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", PORT))
srv.listen(1)
print(f"listening on 127.0.0.1:{PORT} (system voice via `say`)", flush=True)
while True:
    conn, _ = srv.accept()
    print("game connected", flush=True)
    buf = b""
    with conn:
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                line = line.decode("utf-8", "replace").rstrip("\r")
                t = time.strftime("%H:%M:%S")
                if line == "X":
                    print(f"{t} stop", flush=True); stop()
                elif line.startswith("S "):
                    print(f"{t} say: {line[2:]}", flush=True); say(line[2:])
    print("game disconnected", flush=True)

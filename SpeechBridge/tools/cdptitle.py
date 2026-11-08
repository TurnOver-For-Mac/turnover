import socket, os, base64, json, struct, sys, urllib.request
port = int(sys.argv[1]); expr = sys.argv[2]
targets = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=3))
page = next(t for t in targets if t.get("title") == sys.argv[3])
path = page["webSocketDebuggerUrl"].split(str(port), 1)[1]
s = socket.create_connection(("127.0.0.1", port), timeout=5)
key = base64.b64encode(os.urandom(16)).decode()
s.sendall((f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
resp = b""
while b"\r\n\r\n" not in resp: resp += s.recv(4096)
def send(obj):
    data = json.dumps(obj).encode(); mask = os.urandom(4); n = len(data)
    hdr = bytes([0x81]) + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack(">H", n) if n < 65536 else bytes([0x80 | 127]) + struct.pack(">Q", n))
    s.sendall(hdr + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))
def recv_frame():
    hdr = s.recv(2)
    ln = hdr[1] & 0x7f
    if ln == 126: ln = struct.unpack(">H", s.recv(2))[0]
    elif ln == 127: ln = struct.unpack(">Q", s.recv(8))[0]
    buf = b""
    while len(buf) < ln: buf += s.recv(ln - len(buf))
    return buf
send({"id": 1, "method": "Runtime.evaluate", "params": {"expression": expr, "returnByValue": True}})
s.settimeout(5)
while True:
    m = json.loads(recv_frame())
    if m.get("id") == 1:
        r = m.get("result", {}).get("result", {})
        print(json.dumps(r.get("value", r), ensure_ascii=False)[:1500]); break

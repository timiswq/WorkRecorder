"""Loopback FW925 peer for the Swift transport tests. No physical interface is used."""
import socket
import struct
import sys
from pathlib import Path

scenario = sys.argv[1]
name = b"20261116123456"
audio = bytes((i * 31 + 7) % 256 for i in range(20000))
if scenario in ("sync", "repeat"):
    audio = Path(__file__).with_name("silence.bin").read_bytes()
elif scenario == "invalid":
    audio = b"\xff" * 4096
head, tail = b"XnoteWifiHead  ", b"XnoteWifiTail   "


def frame(key, body):
    return head + bytes([key]) + bytes(4) + struct.pack(">I", len(body)) + body + tail


def read_exact(sock, n):
    data = bytearray()
    while len(data) < n:
        part = sock.recv(n - len(data))
        if not part:
            raise EOFError("client disconnected early")
        data.extend(part)
    return data


def read_command(sock, key):
    while True:
        header = read_exact(sock, 24)
        assert header[:15] == head
        payload = read_exact(sock, struct.unpack(">I", header[20:24])[0])
        assert read_exact(sock, len(tail)) == tail
        if header[15] == 53:
            continue
        assert header[15] == key
        return payload


def expect_download(sock, offset):
    assert read_command(sock, 11) == name + struct.pack(">I", offset)


def connect(listener, offset):
    sock, _ = listener.accept()
    sock.settimeout(6)
    assert read_command(sock, 10) == b""
    row = frame(10, b"\0" + name + struct.pack(">I", len(audio))) + frame(10, b"\2")
    sock.sendall(row[:13])
    sock.sendall(row[13:])
    if scenario != "repeat":
        expect_download(sock, offset)
    return sock


with socket.socket() as server:
    server.bind(("127.0.0.1", 0))
    server.listen(2)
    server.settimeout(8)
    print(server.getsockname()[1], flush=True)
    with connect(server, 2048 if scenario == "resume" else 0) as sock:
        if scenario in ("sync", "repeat", "invalid"):
            if scenario != "repeat":
                sock.sendall(frame(11, audio) + frame(11, b"\2"))
            assert read_command(sock, 33) == b""
        elif scenario == "resume":
            sock.sendall(frame(11, audio[2048:]) + frame(11, b"\2"))
        elif scenario == "cancel":
            sock.sendall(frame(11, audio[:4096]))
            assert read_command(sock, 12) == b""
            try:
                sock.sendall(frame(11, b"\2"))
            except OSError:
                pass
        elif scenario == "early":
            sock.sendall(frame(11, audio[:-168]) + frame(11, b"\2"))
            expect_download(sock, len(audio) - 168)
            sock.sendall(frame(11, audio[-168:]) + frame(11, b"\2"))
        else:
            for i in range(3 if scenario == "limit" else 1):
                sock.sendall(frame(11, audio[i*1024:(i+1)*1024]) + frame(11, b"\2"))
                if i < 2:
                    expect_download(sock, (i + 1) * 1024)
            if scenario == "stalled":
                sock.sendall(frame(11, b"\2"))
        if scenario != "cancel":
            sock.recv(1)
    if scenario == "cancel":
        with connect(server, 4096) as sock:
            sock.sendall(frame(11, audio[4096:]) + frame(11, b"\2"))
            sock.recv(1)

"""Offline reference for the observed WebShuttle node wire protocol.

This file connects to sockets supplied by the caller only. It never discovers or
contacts WebShuttle infrastructure. It is research code, not an iOS proxy.
"""
import struct
import time


def probe_request(version: int, fingerprint: bytes, now_ms: int | None = None) -> bytes:
    if len(fingerprint) > 32:
        raise ValueError('fingerprint exceeds 32 bytes')
    timestamp = int(time.time() * 1000) if now_ms is None else now_ms
    return struct.pack('>BQI32sB', 11, timestamp, version, fingerprint, 0)


def read_exact(sock, count: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < count:
        chunk = sock.recv(count - len(chunks))
        if not chunk:
            raise EOFError('unexpected connection close')
        chunks.extend(chunk)
    return bytes(chunks)


def xor(data: bytes, key: int) -> bytes:
    if not 0 <= key <= 127:
        raise ValueError('invalid key')
    return bytes(value ^ key for value in data)


def probe(sock, version: int, fingerprint: bytes) -> int:
    sock.sendall(probe_request(version, fingerprint))
    reply = read_exact(sock, 12)
    if reply[0] != 12 or reply[9] != 0 or reply[10] > 127:
        raise ValueError('node probe rejected or invalid')
    return reply[10]


def establish(sock, key: int, socks_request: bytes) -> None:
    if len(socks_request) < 7 or socks_request[0] != 5 or socks_request[1] != 1:
        raise ValueError('expected SOCKS5 CONNECT request')
    sock.sendall(xor(b'\x07\x00', key))
    first = xor(read_exact(sock, 2), key)
    if first[0] != 8:
        raise ValueError('first handshake rejected')
    command = bytes([9]) + socks_request[1:]
    sock.sendall(xor(command, key))
    second = xor(read_exact(sock, 2), key)
    if second != b'\x0a\x00':
        raise ValueError('connection rejected')


def read_socks_request(sock) -> bytes:
    header = read_exact(sock, 4)
    version, command, reserved, address_type = header
    if version != 5 or command != 1 or reserved != 0:
        raise ValueError('only SOCKS5 CONNECT is supported')
    if address_type == 1:
        address = read_exact(sock, 4)
    elif address_type == 4:
        address = read_exact(sock, 16)
    elif address_type == 3:
        size = read_exact(sock, 1)
        if size[0] == 0:
            raise ValueError('empty domain')
        address = size + read_exact(sock, size[0])
    else:
        raise ValueError('unsupported address type')
    return header + address + read_exact(sock, 2)


def accept_socks_greeting(sock) -> None:
    version, count = read_exact(sock, 2)
    if version != 5 or count == 0:
        raise ValueError('invalid SOCKS greeting')
    methods = read_exact(sock, count)
    if 0 not in methods:
        sock.sendall(b'\x05\xff')
        raise ValueError('no supported SOCKS auth method')
    sock.sendall(b'\x05\x00')


def relay_once(source, destination, key: int, count: int = 8192) -> bool:
    data = source.recv(count)
    if not data:
        return False
    destination.sendall(xor(data, key))
    return True

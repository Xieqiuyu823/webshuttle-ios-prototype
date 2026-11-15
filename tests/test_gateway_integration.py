"""End-to-end checks of the Swift local SOCKS gateway against a local mock.

The test binds only loopback addresses; no real WebShuttle service is contacted.
"""
import argparse
import os
import selectors
import socket
import subprocess
import sys
import threading
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from research.proxy_protocol import read_exact, read_socks_request, xor

GATEWAY_BIN = os.environ.get("GATEWAY_BIN")
KEY = 41


def listener():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    s.listen(4)
    s.settimeout(12)
    return s


def launch_gateway(upstream_port):
    proc = subprocess.Popen([GATEWAY_BIN, "127.0.0.1", str(upstream_port), str(KEY)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    sel = selectors.DefaultSelector()
    sel.register(proc.stdout, selectors.EVENT_READ)
    try:
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if not sel.select(max(0, deadline - time.monotonic())):
                break
            line = proc.stdout.readline()
            if line.startswith("GATEWAY_READY="):
                port, username, password = line.partition("=")[2].split()
                return proc, int(port), username, password
            if not line and proc.poll() is not None:
                break
        proc.terminate()
        out, err = proc.communicate(timeout=5)
        # Do not print harness stdout: it can contain generated credentials.
        raise RuntimeError("Gateway did not start: " + err[-1000:])
    except BaseException:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=5)
        raise
    finally:
        sel.close()


def terminate(proc):
    if proc.poll() is None:
        proc.terminate()
    try:
        proc.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.communicate(timeout=5)


def fragmented_send(sock, data):
    for b in data:
        sock.sendall(bytes([b]))
        time.sleep(0.001)


def authenticate(client, username, password, *, fragment=False):
    user, secret = username.encode(), password.encode()
    assert 0 < len(user) <= 255 and 0 < len(secret) <= 255
    send = fragmented_send if fragment else lambda sock, data: sock.sendall(data)
    send(client, b"\x05\x01\x02")
    if read_exact(client, 2) != b"\x05\x02":
        raise AssertionError("gateway did not select username/password authentication")
    send(client, b"\x01" + bytes([len(user)]) + user + bytes([len(secret)]) + secret)
    return read_exact(client, 2)


class GatewayIntegrationTest(unittest.TestCase):
    def test_requires_credentials_before_connecting_upstream(self):
        remote = listener()
        proc, local_port, username, password = launch_gateway(remote.getsockname()[1])
        try:
            with socket.create_connection(("127.0.0.1", local_port), timeout=10) as client:
                client.settimeout(8)
                fragmented_send(client, b"\x05\x01\x00")
                self.assertEqual(read_exact(client, 2), b"\x05\xff")
            with socket.create_connection(("127.0.0.1", local_port), timeout=10) as client:
                client.settimeout(8)
                status = authenticate(client, username, "wrong-" + password, fragment=True)
                self.assertEqual(status, b"\x01\x01")
            remote.settimeout(1)
            with self.assertRaises(socket.timeout):
                remote.accept()
        finally:
            terminate(proc)
            remote.close()

    def test_fragmented_handshake_and_bidirectional_stream(self):
        remote = listener()
        errors = []
        request = b"\x05\x01\x00\x03\x0bexample.com\x01\xbb"
        payload = bytes(range(256)) * 400
        reply = bytes(range(255, -1, -1)) * 40

        def mock_node():
            try:
                conn, _ = remote.accept()
                with conn:
                    conn.settimeout(12)
                    self.assertEqual(xor(read_exact(conn, 2), KEY), b"\x07\x00")
                    fragmented_send(conn, xor(b"\x08\x00", KEY))
                    header = xor(read_exact(conn, 4), KEY)
                    self.assertEqual(header, b"\x09\x01\x00\x03")
                    length = xor(read_exact(conn, 1), KEY)
                    remainder = xor(read_exact(conn, length[0] + 2), KEY)
                    self.assertEqual(header + length + remainder, b"\x09" + request[1:])
                    fragmented_send(conn, xor(b"\x0a\x00", KEY))
                    self.assertEqual(xor(read_exact(conn, len(payload)), KEY), payload)
                    conn.sendall(xor(reply, KEY))
            except BaseException as exc:
                errors.append(exc)
            finally:
                remote.close()

        worker = threading.Thread(target=mock_node, daemon=True)
        worker.start()
        proc, local_port, username, password = launch_gateway(remote.getsockname()[1])
        try:
            with socket.create_connection(("127.0.0.1", local_port), timeout=10) as client:
                client.settimeout(12)
                self.assertEqual(authenticate(client, username, password, fragment=True), b"\x01\x00")
                fragmented_send(client, request)
                head = read_exact(client, 4)
                self.assertEqual(head[:2], b"\x05\x00")
                if head[3] == 1:
                    read_exact(client, 6)
                elif head[3] == 4:
                    read_exact(client, 18)
                elif head[3] == 3:
                    size = read_exact(client, 1)[0]
                    read_exact(client, size + 2)
                else:
                    self.fail("invalid SOCKS address type")
                client.sendall(payload)
                self.assertEqual(read_exact(client, len(reply)), reply)
            worker.join(timeout=15)
            self.assertFalse(worker.is_alive(), "mock node did not finish")
            if errors:
                raise errors[0]
        finally:
            terminate(proc)
            remote.close()

    def test_failed_node_never_connects_target_directly(self):
        # The mock node rejects the upstream handshake. The advertised target is
        # a loopback listener: any accepted connection means a privacy failure.
        remote, decoy = listener(), listener()
        remote_port = remote.getsockname()[1]
        decoy_port = decoy.getsockname()[1]
        remote_done = threading.Event()
        def reject():
            try:
                conn, _ = remote.accept()
                with conn:
                    conn.settimeout(5)
                    read_exact(conn, 2)
                    conn.sendall(xor(b"\x09\x00", KEY))
            finally:
                remote.close()
                remote_done.set()
        worker = threading.Thread(target=reject, daemon=True)
        worker.start()
        proc, local_port, username, password = launch_gateway(remote_port)
        try:
            with socket.create_connection(("127.0.0.1", local_port), timeout=10) as client:
                client.settimeout(8)
                self.assertEqual(authenticate(client, username, password), b"\x01\x00")
                try:
                    client.sendall(b"\x05\x01\x00\x01\x7f\x00\x00\x01" + decoy_port.to_bytes(2, "big"))
                    response = client.recv(16)
                except (ConnectionResetError, BrokenPipeError, EOFError):
                    response = b""
                self.assertNotEqual(response[:2], b"\x05\x00", "failed upstream returned SOCKS success")
            remote_done.wait(10)
            decoy.settimeout(1)
            with self.assertRaises(socket.timeout):
                decoy.accept()
        finally:
            terminate(proc)
            remote.close()
            decoy.close()
            worker.join(timeout=2)


if __name__ == "__main__":
    if not GATEWAY_BIN:
        raise SystemExit("Set GATEWAY_BIN to the compiled Swift harness")
    unittest.main(verbosity=2)

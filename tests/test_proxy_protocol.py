import socket
import threading
import unittest
from research.proxy_protocol import establish, probe, read_exact, xor


class ProtocolTest(unittest.TestCase):
    def test_fragmented_probe_and_handshake(self):
        probe_client, probe_server = socket.socketpair()
        client, server = socket.socketpair()
        failures = []
        request = b'\x05\x01\x00\x03\x0bexample.com\x01\xbb'
        key = 41
        def node():
            try:
                frame = read_exact(probe_server, 46)
                self.assertEqual(frame[0], 11)
                self.assertEqual(frame[9:13], (725).to_bytes(4, 'big'))
                reply = b'\x0c' + bytes(8) + b'\x00' + bytes([key, 0])
                for b in reply:
                    probe_server.sendall(bytes([b]))
                probe_server.close()
                self.assertEqual(xor(read_exact(server, 2), key), b'\x07\x00')
                server.sendall(xor(b'\x08\x00', key))
                self.assertEqual(xor(read_exact(server, len(request)), key), b'\x09' + request[1:])
                server.sendall(xor(b'\x0a\x00', key))
            except BaseException as exc:
                failures.append(exc)
            finally:
                server.close()
        worker = threading.Thread(target=node)
        worker.start()
        try:
            self.assertEqual(probe(probe_client, 725, b'fixture'), key)
            probe_client.close()
            establish(client, key, request)
        finally:
            probe_client.close()
            client.close()
            worker.join()
        if failures:
            raise failures[0]

    def test_rejects_failed_probe_and_connection(self):
        client, server = socket.socketpair()
        server.sendall(b'\x0c' + bytes(8) + b'\x01\x00\x00')
        try:
            with self.assertRaises(ValueError):
                probe(client, 725, b'fixture')
        finally:
            client.close()
            server.close()
        with self.assertRaises(ValueError):
            xor(b'test', 128)

if __name__ == '__main__':
    unittest.main()

class SocksTest(unittest.TestCase):
    def test_fragmented_greeting_domain_and_forwarding(self):
        from research.proxy_protocol import accept_socks_greeting, read_socks_request, relay_once
        client, server = socket.socketpair()
        left, right = socket.socketpair()
        request = b'\x05\x01\x00\x03\x0bexample.com\x01\xbb'
        try:
            client.sendall(b'\x05\x02\x02\x00' + request + b'plaintext')
            accept_socks_greeting(server)
            self.assertEqual(read_exact(client, 2), b'\x05\x00')
            self.assertEqual(read_socks_request(server), request)
            self.assertTrue(relay_once(server, left, 41))
            self.assertEqual(xor(read_exact(right, 9), 41), b'plaintext')
        finally:
            client.close(); server.close(); left.close(); right.close()

    def test_unsupported_command_is_rejected(self):
        from research.proxy_protocol import read_socks_request
        client, server = socket.socketpair()
        try:
            client.sendall(b'\x05\x03\x00\x01')
            with self.assertRaises(ValueError):
                read_socks_request(server)
        finally:
            client.close(); server.close()

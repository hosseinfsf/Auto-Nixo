import asyncio
import unittest

from nixo_engine.mt5_protocol import Mt5Message
from nixo_engine.server import NixoLinkServer


class ServerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.server = NixoLinkServer("127.0.0.1", 0, "x" * 32)
        await self.server.start()

    async def asyncTearDown(self):
        await self.server.stop()

    async def connect(self, token="x" * 32):
        r, w = await asyncio.open_connection("127.0.0.1", self.server.port)
        w.write(Mt5Message({"CMD": "AUTH", "TOKEN": token}).encode())
        await w.drain()
        return r, w, Mt5Message.decode(await r.readline())

    async def register(self, login, equity="900"):
        r, w, reply = await self.connect()
        self.assertEqual(reply.command, "AUTH_OK")
        w.write(Mt5Message({"CMD": "ACCOUNT", "LOGIN": str(login),
                            "EQUITY": equity}).encode())
        await w.drain()
        for _ in range(50):
            if login in self.server.connections:
                break
            await asyncio.sleep(.01)
        self.assertIn(login, self.server.connections)
        return r, w

    async def test_auth_registers_account(self):
        r, w = await self.register(123)
        self.assertEqual(self.server.connections[123].account["EQUITY"], "900")
        w.close()
        await w.wait_closed()

    async def test_bad_token_rejected(self):
        r, w, reply = await self.connect("z" * 32)
        self.assertEqual(reply.command, "AUTH_FAIL")
        w.close()
        await w.wait_closed()

    async def test_dry_run_blocks_open(self):
        with self.assertRaises(PermissionError):
            await self.server.send_open(123, {"SYMBOL": "XAUUSD"})

    async def test_request_response_correlation(self):
        r, w = await self.register(321)
        task = asyncio.create_task(self.server.request(321, "GET_ACCOUNT"))
        sent = Mt5Message.decode(await r.readline())
        w.write(Mt5Message({"CMD": "ACCOUNT", "REQ_ID": sent.fields["REQ_ID"],
                            "LOGIN": "321", "EQUITY": "1001"}).encode())
        await w.drain()
        got = await task
        self.assertEqual(got.fields["EQUITY"], "1001")
        w.close()
        await w.wait_closed()

    async def test_request_cannot_be_spoofed_by_fields(self):
        await self.register(456)
        with self.assertRaises(ValueError):
            await self.server.request(456, "GET_ACCOUNT",
                                      {"REQ_ID": "spoofed", "CMD": "CLOSE_ALL"})

    async def test_unknown_command_is_rejected_before_write(self):
        await self.register(789)
        with self.assertRaises(ValueError):
            await self.server.request(789, "EXECUTE_ANYTHING")


if __name__ == "__main__":
    unittest.main()

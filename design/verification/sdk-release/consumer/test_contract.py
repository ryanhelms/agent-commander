import asyncio
import json
import re
import unittest
from pathlib import Path

from google.protobuf.json_format import MessageToDict, ParseDict

from agentacp import Sessions, model

FIXTURE = Path(__file__).resolve().parents[3] / "conformance" / "session.json"


class ScriptedRuntime:
    def __init__(self, test, steps):
        self.test = test
        self.remaining = iter(steps)
        self.delivered = 0
        self.closed = False
        self.block_after_first = False

    def take(self, operation, request):
        step = next(self.remaining)
        self.test.assertEqual(operation, step["operation"])
        self.test.assertEqual(MessageToDict(request), step["request"])
        return step

    async def unary(self, operation, request, response_type):
        step = self.take(operation, request)
        self.test.assertIs(response_type, getattr(model, operation + "Response"))
        return ParseDict(step["replies"][0], response_type())

    async def stream(self, operation, request, response_type):
        step = self.take(operation, request)
        self.test.assertIs(response_type, model.Observation)
        try:
            for reply in step["replies"]:
                self.delivered += 1
                yield ParseDict(reply, response_type())
                if self.block_after_first:
                    await asyncio.Event().wait()
        finally:
            self.closed = True


class SessionContract(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.steps = json.loads(FIXTURE.read_text())

    async def test_shared_contract(self):
        runtime = ScriptedRuntime(self, self.steps)
        client = Sessions(runtime)
        for step in self.steps:
            operation = step["operation"]
            request_type = getattr(model, operation + "Request")
            request = ParseDict(step["request"], request_type())
            method = re.sub(r"(?<!^)(?=[A-Z])", "_", operation).lower()
            if operation == "Observe":
                self.assertEqual(
                    [MessageToDict(event) async for event in client.observe(request)],
                    step["replies"],
                )
                self.assertTrue(runtime.closed)
            else:
                reply = await getattr(client, method)(request)
                self.assertEqual(MessageToDict(reply), step["replies"][0])
        self.assertEqual(list(runtime.remaining), [])

    async def test_cancel_active_observation(self):
        step = next(s for s in self.steps if s["operation"] == "Observe")
        request = ParseDict(step["request"], model.ObserveRequest())
        runtime = ScriptedRuntime(self, [step])
        runtime.block_after_first = True
        events = Sessions(runtime).observe(request)
        first = await anext(events)
        self.assertEqual(MessageToDict(first), step["replies"][0])

        pending = asyncio.create_task(anext(events))
        await asyncio.sleep(0)
        pending.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await pending
        self.assertTrue(runtime.closed)
        self.assertEqual(runtime.delivered, 1)

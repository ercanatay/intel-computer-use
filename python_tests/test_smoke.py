import contextlib
import io
import unittest
from unittest.mock import patch

from scripts import smoke


class CalculatorBridge:
    def __init__(self):
        self.display = "0"
        self.calls = []

    def call(self, command, arguments):
        self.calls.append((command, arguments))
        if command == "status":
            return {"accessibility": True, "post_events": True, "session": "unlocked"}
        if command == "list_windows":
            return {"windows": [{"window_id": 1, "width": 230, "height": 408}]}
        if command == "snapshot":
            return {"nodes": [{"role": "AXStaticText", "value": "\u200e" + self.display}]}
        if command == "type_text":
            self.display += arguments["text"]
        if command == "press_key":
            key = arguments["key"]
            if key == "Escape":
                self.display = ""
            elif key == "Return" and self.display == "12+30":
                self.display = "42"
            elif key in "1230":
                self.display += key
        return {}


class SmokeTests(unittest.TestCase):
    def test_calculator_plus_does_not_depend_on_us_keyboard_layout(self):
        bridge = CalculatorBridge()
        with patch.object(smoke, "NativeBridge", return_value=bridge), patch.object(smoke.time, "sleep"), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(smoke.main(), 0)
        self.assertTrue(any(command == "type_text" and arguments.get("text") == "+" for command, arguments in bridge.calls))
        self.assertFalse(any(arguments.get("key") == "shift+equal" for command, arguments in bridge.calls))


if __name__ == "__main__":
    unittest.main()

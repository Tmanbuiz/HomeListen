"""Check shipped blueprint inputs and render their actual decision templates.

This is a template contract check, not a replacement for Home Assistant/device testing.
Run with PyYAML and Jinja2 installed.
"""
import json
from datetime import datetime, timezone
from pathlib import Path
import unittest

import yaml
from jinja2.nativetypes import NativeEnvironment

ROOT = Path(__file__).resolve().parents[1]


class BlueprintLoader(yaml.SafeLoader):
    pass


BlueprintLoader.add_constructor("!input", lambda loader, node: {"input": loader.construct_scalar(node)})


def load(name):
    return yaml.load((ROOT / "integrations/home_assistant/blueprints" / name).read_text(), Loader=BlueprintLoader)


def from_json(value, default=None):
    try:
        return json.loads(value)
    except (TypeError, ValueError):
        return default


class BlueprintTests(unittest.TestCase):
    def setUp(self):
        self.env = NativeEnvironment()
        self.env.filters["to_json"] = json.dumps
        self.env.filters["from_json"] = from_json
        self.now = datetime(2026, 10, 10, 12, tzinfo=timezone.utc)
        self.env.globals.update(now=lambda: self.now, as_timestamp=lambda dt: dt.timestamp())

    def render_sound(self, **changes):
        sound = dict(event_type="crying", event_id="0123456789abcdef01234567",
                     observed_at_ms=int(self.now.timestamp() * 1000), profile="night", quiet=False)
        sound.update(changes)
        template = load("sound_response.yaml")["actions"][1]["value_template"]
        return self.env.from_string(template).render(sound=sound, selected_categories=["crying"],
                                                     selected_profiles=["night"], remembered=[])

    def test_fresh_selected_sound(self):
        self.assertIs(self.render_sound(), True)

    def test_stale_future_quiet_and_unselected_sounds(self):
        for changes in [dict(observed_at_ms=int(self.now.timestamp() * 1000) - 60_000),
                        dict(observed_at_ms=int(self.now.timestamp() * 1000) + 30_001),
                        dict(quiet=True), dict(profile="away"), dict(event_type="test"),
                        dict(event_id=""), dict(event_id="x" * 25)]:
            with self.subTest(changes=changes):
                self.assertIs(self.render_sound(**changes), False)

    def test_duplicate_ids_checked_inside_queued_actions(self):
        blueprint = load("sound_response.yaml")
        self.assertEqual(blueprint["mode"], "queued")
        template = blueprint["actions"][1]["value_template"]
        sound = dict(event_type="crying", event_id="known", observed_at_ms=self.now.timestamp() * 1000,
                     profile="night", quiet=False)
        self.assertIs(self.env.from_string(template).render(sound=sound, selected_categories=["crying"],
                       selected_profiles=["night"], remembered=["known"]), False)

    def test_helper_ring_fits_255_characters_and_remembers_latest_ids(self):
        template = load("sound_response.yaml")["actions"][2]["data"]["value"]
        remembered = [f"{i:024x}" for i in range(10)]
        # NativeEnvironment may deserialize JSON back to a native list.
        result = self.env.from_string(template).render(remembered=remembered, sound={"event_id": "f" * 24})
        ids = from_json(result) if isinstance(result, str) else result
        self.assertEqual(len(ids), 8)
        self.assertEqual(ids[-1], "f" * 24)
        self.assertLessEqual(len(json.dumps(ids)), 255)

    def test_monitor_failure_requires_active_monitoring(self):
        blueprint = load("monitor_health.yaml")
        offline = blueprint["triggers"][0]
        self.assertEqual((offline["from"], offline["to"], offline["for"]), ("on", "unavailable", "00:00:45"))
        template = self.env.from_string(blueprint["triggers"][1]["value_template"])
        for monitoring, microphone, detector, expected in [
            ("on", "on", "on", False), ("on", "off", "on", True),
            ("on", "on", "unavailable", True), ("off", "off", "off", False),
            ("unknown", "unknown", "unknown", False)]:
            states = {"monitoring": monitoring, "microphone": microphone, "detector": detector}
            result = template.render(monitoring_entity="monitoring", microphone_entity="microphone",
                                     detector_entity="detector", is_state=lambda name, state: states[name] == state)
            self.assertIs(result, expected)

    def test_all_blueprint_inputs_exist_and_user_response_is_present(self):
        def references(node):
            if isinstance(node, dict):
                if set(node) == {"input"}:
                    yield node["input"]
                else:
                    for value in node.values():
                        yield from references(value)
            elif isinstance(node, list):
                for value in node:
                    yield from references(value)
        for name in ["sound_response.yaml", "monitor_health.yaml"]:
            blueprint = load(name)
            self.assertEqual(blueprint["blueprint"]["domain"], "automation")
            inputs = blueprint["blueprint"]["input"]
            self.assertTrue(set(references(blueprint)).issubset(inputs))
            self.assertEqual(inputs["response"]["selector"], {"action": None})


if __name__ == "__main__":
    unittest.main()

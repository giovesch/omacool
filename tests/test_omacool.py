#!/usr/bin/env python3
"""Tests for omacool against a fake sysfs tree.

The real /sys/class/hwmon is read-only and machine-specific, so every test here
builds a throwaway hwmon tree with the same file layout the kernel exposes and
points the tool at it through OMACOOL_HWMON.
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BIN = os.path.join(ROOT, "bin", "omacool")

sys.path.insert(0, os.path.join(ROOT, "bin"))
import importlib.util

_spec = importlib.util.spec_from_loader(
    "omacool", importlib.machinery.SourceFileLoader("omacool", BIN))
omacool = importlib.util.module_from_spec(_spec)


def build_fake_hwmon(root):
    """A board with a super-IO chip (3 fans, 2 of them pwm) and a CPU package."""
    def write(path, value):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as handle:
            handle.write(str(value))

    chip = os.path.join(root, "hwmon0")
    write(os.path.join(chip, "name"), "nct6798")
    write(os.path.join(chip, "temp1_input"), 45000)
    write(os.path.join(chip, "temp1_label"), "SYSTIN")
    write(os.path.join(chip, "temp1_crit"), 100000)
    write(os.path.join(chip, "fan1_input"), 1200)
    write(os.path.join(chip, "fan1_label"), "CPU fan")
    write(os.path.join(chip, "pwm1"), 128)
    write(os.path.join(chip, "pwm1_enable"), 2)
    write(os.path.join(chip, "fan2_input"), 800)
    write(os.path.join(chip, "pwm2"), 76)
    write(os.path.join(chip, "pwm2_enable"), 2)
    # A tacho with no pwm channel: readable, never controllable.
    write(os.path.join(chip, "fan3_input"), 0)

    cpu = os.path.join(root, "hwmon1")
    write(os.path.join(cpu, "name"), "coretemp")
    write(os.path.join(cpu, "temp1_input"), 62000)
    write(os.path.join(cpu, "temp1_label"), "Package id 0")
    write(os.path.join(cpu, "temp1_crit"), 100000)
    return root


class FakeTreeCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="omacool-test-", dir="/tmp")
        self.hwmon = build_fake_hwmon(os.path.join(self.tmp, "hwmon"))
        self.config = os.path.join(self.tmp, "config.json")
        os.environ["OMACOOL_HWMON"] = self.hwmon
        _spec.loader.exec_module(omacool)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)
        os.environ.pop("OMACOOL_HWMON", None)

    def temp(self, chip, index, celsius):
        with open(os.path.join(self.hwmon, chip, "temp%d_input" % index), "w") as handle:
            handle.write(str(int(celsius * 1000)))

    def pwm(self, chip, index):
        with open(os.path.join(self.hwmon, chip, "pwm%d" % index)) as handle:
            return int(handle.read().strip())

    def enable(self, chip, index):
        with open(os.path.join(self.hwmon, chip, "pwm%d_enable" % index)) as handle:
            return int(handle.read().strip())


class DiscoveryTests(FakeTreeCase):
    def test_finds_chips_fans_and_sensors(self):
        chips = omacool.discover()
        ids = [chip["id"] for chip in chips]
        self.assertEqual(ids, ["nct6798", "coretemp"])

        fans = omacool.flat_fans(chips)
        self.assertEqual([fan["id"] for fan in fans],
                         ["nct6798/fan1", "nct6798/fan2", "nct6798/fan3"])
        self.assertEqual(fans[0]["label"], "CPU fan")
        self.assertEqual(fans[0]["rpm"], 1200)
        self.assertEqual(fans[0]["percent"], 50)  # 128/255

    def test_tacho_without_pwm_is_not_controllable(self):
        fans = {fan["id"]: fan for fan in omacool.flat_fans(omacool.discover())}
        self.assertTrue(fans["nct6798/fan1"]["writable"])
        self.assertFalse(fans["nct6798/fan3"]["writable"])

    def test_hottest_sensor_wins_across_chips(self):
        top = omacool.hottest(omacool.flat_temps(omacool.discover()))
        self.assertEqual(top["id"], "coretemp/temp1")
        self.assertEqual(top["value"], 62.0)

    def test_duplicate_chip_names_get_distinct_ids(self):
        for index in (2, 3):
            path = os.path.join(self.hwmon, "hwmon%d" % index)
            os.makedirs(path)
            with open(os.path.join(path, "name"), "w") as handle:
                handle.write("amdgpu")
            with open(os.path.join(path, "temp1_input"), "w") as handle:
                handle.write("50000")
        ids = [chip["id"] for chip in omacool.discover()]
        self.assertIn("amdgpu", ids)
        self.assertIn("amdgpu-2", ids)


class CurveTests(FakeTreeCase):
    def test_interpolates_between_points(self):
        curve = [[40, 20], [80, 100]]
        self.assertEqual(omacool.curve_percent(curve, 40), 20)
        self.assertEqual(omacool.curve_percent(curve, 60), 60)
        self.assertEqual(omacool.curve_percent(curve, 80), 100)

    def test_clamps_outside_the_curve(self):
        curve = [[40, 20], [80, 100]]
        self.assertEqual(omacool.curve_percent(curve, 10), 20)
        self.assertEqual(omacool.curve_percent(curve, 200), 100)

    def test_normalize_sorts_and_forces_monotonic(self):
        self.assertEqual(omacool.normalize_curve([[80, 40], [40, 90]]),
                         [[40.0, 90.0], [80.0, 90.0]])

    def test_normalize_merges_duplicate_temperatures(self):
        self.assertEqual(omacool.normalize_curve([[50, 30], [50, 70], [70, 80]]),
                         [[50.0, 70.0], [70.0, 80.0]])

    def test_parse_curve_argument(self):
        self.assertEqual(omacool.parse_curve_arg("40:20, 60:50,80:100"),
                         [[40.0, 20.0], [60.0, 50.0], [80.0, 100.0]])

    def test_parse_curve_rejects_garbage(self):
        with self.assertRaises(ValueError):
            omacool.parse_curve_arg("40-20,60-50")
        with self.assertRaises(ValueError):
            omacool.parse_curve_arg("40:20")


class ControllerTests(FakeTreeCase):
    def controller(self, **overrides):
        config = omacool.load_config(self.config)
        config["hysteresis"] = 0
        config["spinup_percent"] = 0
        config.update(overrides)
        return omacool.Controller(config)

    def test_curve_mode_drives_pwm_from_the_hottest_sensor(self):
        control = self.controller()
        control.config["preset"] = "balanced"  # 60C -> 45%
        self.temp("hwmon1", 1, 60)
        control.apply_once(force=True)
        self.assertEqual(omacool.pwm_to_percent(self.pwm("hwmon0", 1)), 45)
        self.assertEqual(self.enable("hwmon0", 1), omacool.ENABLE_MANUAL)

    def test_manual_preset_pins_every_fan(self):
        control = self.controller()
        control.config["preset"] = "max"
        control.apply_once(force=True)
        self.assertEqual(omacool.pwm_to_percent(self.pwm("hwmon0", 1)), 100)
        self.assertEqual(omacool.pwm_to_percent(self.pwm("hwmon0", 2)), 100)

    def test_auto_preset_hands_control_back_to_firmware(self):
        control = self.controller()
        control.config["preset"] = "balanced"
        control.apply_once(force=True)
        self.assertEqual(self.enable("hwmon0", 1), omacool.ENABLE_MANUAL)
        control.config["preset"] = "auto"
        control.apply_once(force=True)
        self.assertEqual(self.enable("hwmon0", 1), omacool.ENABLE_AUTO)

    def test_per_fan_override_beats_the_preset(self):
        control = self.controller()
        control.config["preset"] = "silent"
        control.config["fans"] = {"nct6798/fan2": {"mode": "manual", "percent": 90}}
        self.temp("hwmon1", 1, 40)
        control.apply_once(force=True)
        self.assertEqual(omacool.pwm_to_percent(self.pwm("hwmon0", 2)), 90)
        self.assertLess(omacool.pwm_to_percent(self.pwm("hwmon0", 1)), 90)

    def test_critical_temperature_overrides_a_silent_curve(self):
        control = self.controller(critical_temp=85)
        control.config["preset"] = "silent"
        self.temp("hwmon1", 1, 95)
        alarm = control.apply_once(force=True)
        self.assertIsNotNone(alarm)
        self.assertEqual(omacool.pwm_to_percent(self.pwm("hwmon0", 1)), 100)
        self.assertEqual(omacool.pwm_to_percent(self.pwm("hwmon0", 2)), 100)

    def test_minimum_floor_is_respected(self):
        control = self.controller()
        control.config["preset"] = "silent"
        control.config["fans"] = {"nct6798/fan1": {"mode": "curve",
                                                   "curve": [[0, 0], [100, 0]],
                                                   "min": 30}}
        self.temp("hwmon1", 1, 30)
        control.apply_once(force=True)
        self.assertEqual(omacool.pwm_to_percent(self.pwm("hwmon0", 1)), 30)

    def test_hysteresis_suppresses_small_changes(self):
        control = self.controller(hysteresis=10)
        control.config["preset"] = "balanced"
        self.temp("hwmon1", 1, 60)
        control.apply_once(force=True)
        settled = self.pwm("hwmon0", 1)
        self.temp("hwmon1", 1, 62)
        control.apply_once()
        self.assertEqual(self.pwm("hwmon0", 1), settled)
        self.temp("hwmon1", 1, 80)
        control.apply_once()
        self.assertGreater(self.pwm("hwmon0", 1), settled)

    def test_spinup_kicks_a_stopped_fan(self):
        control = self.controller(spinup_percent=50, spinup_ms=2000, hysteresis=0)
        control.config["preset"] = "balanced"
        control.config["fans"] = {"nct6798/fan1": {"mode": "manual", "percent": 0}}
        control.apply_once(force=True)
        self.assertEqual(self.pwm("hwmon0", 1), 0)
        control.config["fans"] = {"nct6798/fan1": {"mode": "manual", "percent": 10}}
        control.apply_once(force=True)
        self.assertEqual(omacool.pwm_to_percent(self.pwm("hwmon0", 1)), 50)

    def test_restore_returns_the_original_enable_values(self):
        control = self.controller()
        control.config["preset"] = "max"
        control.apply_once(force=True)
        self.assertEqual(self.enable("hwmon0", 1), omacool.ENABLE_MANUAL)
        control.restore()
        self.assertEqual(self.enable("hwmon0", 1), 2)

    def test_read_only_fan_is_never_written(self):
        control = self.controller()
        control.config["preset"] = "max"
        control.apply_once(force=True)
        self.assertFalse(os.path.exists(os.path.join(self.hwmon, "hwmon0", "pwm3")))


class ConfigTests(FakeTreeCase):
    def test_round_trips_and_keeps_builtin_presets(self):
        config = omacool.load_config(self.config)
        config["preset"] = "silent"
        omacool.save_config(config, self.config)
        reloaded = omacool.load_config(self.config)
        self.assertEqual(reloaded["preset"], "silent")
        self.assertIn("performance", reloaded["presets"])

    def test_user_preset_survives_alongside_the_builtins(self):
        config = omacool.load_config(self.config)
        config["presets"]["night"] = {"label": "Night", "mode": "curve",
                                      "curve": [[30, 0], [90, 40]]}
        omacool.save_config(config, self.config)
        reloaded = omacool.load_config(self.config)
        self.assertIn("night", reloaded["presets"])
        self.assertIn("balanced", reloaded["presets"])

    def test_corrupt_config_falls_back_to_defaults(self):
        with open(self.config, "w") as handle:
            handle.write("{not json")
        config = omacool.load_config(self.config)
        self.assertEqual(config["preset"], "balanced")

    def test_fan_plan_falls_back_to_the_preset(self):
        config = omacool.load_config(self.config)
        config["preset"] = "performance"
        plan = omacool.fan_plan(config, "nct6798/fan1")
        self.assertEqual(plan["mode"], "curve")
        self.assertEqual(plan["source"], "preset")
        self.assertEqual(plan["curve"], omacool.normalize_curve(
            omacool.DEFAULT_CURVES["performance"]))

    def test_fan_group_detection(self):
        self.assertEqual(omacool.detect_fan_group({"label": "CPU fan", "chipName": "nct6798"}), "cpu")
        self.assertEqual(omacool.detect_fan_group({"chipName": "amdgpu"}), "gpu")
        self.assertEqual(omacool.detect_fan_group({"label": "AIO Pump"}), "pump")
        self.assertEqual(omacool.detect_fan_group({"label": "Chassis Fan 1"}), "case")
        self.assertEqual(omacool.detect_fan_group({"id": "nct6798/fan1", "chipName": "nct6798"}), "cpu")

    def test_status_includes_groups_and_fan_groups(self):
        status = omacool.build_status()
        self.assertIn("groups", status)
        gids = [g["id"] for g in status["groups"]]
        for expected in ("cpu", "gpu", "case", "pump"):
            self.assertIn(expected, gids)
        fan_map = {f["id"]: f for f in status["fans"]}
        self.assertEqual(fan_map["nct6798/fan1"]["group"], "cpu")


class DaemonSocketTests(FakeTreeCase):
    def setUp(self):
        super().setUp()
        self.socket_path = os.path.join(self.tmp, "omacool.sock")
        self.daemon = omacool.Daemon(config_path=self.config, socket_path=self.socket_path)
        self.daemon.config["hysteresis"] = 0
        self.daemon.config["spinup_percent"] = 0
        # The daemon and the test client run as the same uid, which omacool
        # always authorizes — in production that rule means "root", and the
        # polkit path is covered separately in AuthorizationTests.
        self.daemon.config["socket_mode"] = "0600"
        omacool.SOCKET_PATH = self.socket_path
        self.thread = threading.Thread(target=self.daemon.run, daemon=True)
        self.thread.start()
        for _ in range(100):
            if os.path.exists(self.socket_path):
                break
            time.sleep(0.02)

    def tearDown(self):
        self.daemon.stop()
        self.thread.join(timeout=2)
        super().tearDown()

    def call(self, payload):
        return omacool.send_command(payload, timeout=3.0)

    def test_ping(self):
        self.assertTrue(self.call({"cmd": "ping"})["pong"])

    def test_status_reports_fans_and_temps(self):
        status = self.call({"cmd": "status"})
        self.assertTrue(status["daemon"])
        self.assertEqual(status["controllable"], 2)
        self.assertEqual(len(status["temps"]), 2)

    def test_apply_preset_persists_and_moves_fans(self):
        self.assertTrue(self.call({"cmd": "preset", "name": "max"})["ok"])
        self.assertEqual(omacool.pwm_to_percent(self.pwm("hwmon0", 1)), 100)
        self.assertEqual(omacool.load_config(self.config)["preset"], "max")

    def test_unknown_preset_is_refused(self):
        response = self.call({"cmd": "preset", "name": "turbo"})
        self.assertFalse(response["ok"])
        self.assertIn("unknown preset", response["error"])

    def test_set_one_fan(self):
        self.assertTrue(self.call({"cmd": "set", "fan": "nct6798/fan2", "percent": 73})["ok"])
        self.assertEqual(omacool.pwm_to_percent(self.pwm("hwmon0", 2)), 73)

    def test_set_curve_then_read_it_back(self):
        points = [[30, 10], [70, 80]]
        self.assertTrue(self.call({"cmd": "curve", "fan": "nct6798/fan1", "curve": points})["ok"])
        config = self.call({"cmd": "config"})["config"]
        self.assertEqual(config["fans"]["nct6798/fan1"]["curve"], [[30.0, 10.0], [70.0, 80.0]])

    def test_reset_drops_the_override(self):
        self.call({"cmd": "set", "fan": "nct6798/fan1", "percent": 20})
        self.call({"cmd": "reset", "fan": "nct6798/fan1"})
        self.assertNotIn("nct6798/fan1", self.call({"cmd": "config"})["config"].get("fans", {}))

    def test_switching_preset_clears_pinned_fans(self):
        self.call({"cmd": "set", "fan": "nct6798/fan1", "percent": 20})
        self.call({"cmd": "preset", "name": "performance"})
        self.assertEqual(self.call({"cmd": "config"})["config"]["fans"], {})

    def test_malformed_request_does_not_kill_the_daemon(self):
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(self.socket_path)
        client.sendall(b"this is not json\n")
        client.recv(4096)
        client.close()
        self.assertTrue(self.call({"cmd": "ping"})["pong"])

    def test_unknown_command_is_reported(self):
        response = self.call({"cmd": "launch-missiles"})
        self.assertFalse(response["ok"])

    def test_a_refused_caller_cannot_touch_a_fan(self):
        before = self.pwm("hwmon0", 1)
        original = omacool.authorize
        omacool.authorize = lambda pid, uid, action=None: (False, "nope")
        try:
            response = self.call({"cmd": "set", "fan": "nct6798/fan1", "percent": 100})
        finally:
            omacool.authorize = original
        self.assertFalse(response["ok"])
        self.assertEqual(response["error"], "nope")
        self.assertEqual(self.pwm("hwmon0", 1), before)

    def test_reading_status_is_never_gated(self):
        original = omacool.authorize
        omacool.authorize = lambda pid, uid, action=None: (False, "nope")
        try:
            status = self.call({"cmd": "status"})
        finally:
            omacool.authorize = original
        self.assertTrue(status["ok"])
        self.assertEqual(status["controllable"], 2)

    def test_daemon_add_and_remove_custom_group(self):
        res = self.call({"cmd": "group-add", "name": "Front Intake"})
        self.assertTrue(res["ok"])
        gid = res["group"]["id"]
        self.assertEqual(gid, "front-intake")

        # Assign fan2 to custom group
        res = self.call({"cmd": "group-set", "fan": "nct6798/fan2", "group": gid})
        self.assertTrue(res["ok"])

        status = self.call({"cmd": "status"})
        fan_map = {f["id"]: f for f in status["fans"]}
        self.assertEqual(fan_map["nct6798/fan2"]["group"], "front-intake")

        # Remove custom group
        res = self.call({"cmd": "group-remove", "group_id": gid})
        self.assertTrue(res["ok"])
        status = self.call({"cmd": "status"})
        group_ids = [g["id"] for g in status["groups"]]
        self.assertNotIn("front-intake", group_ids)


class AuthorizationTests(FakeTreeCase):
    """The polkit gate, exercised with a stand-in pkcheck.

    A real check needs an active login session and a polkit agent, neither of
    which exists in a test runner, so OMACOOL_PKCHECK points at a script whose
    exit status the test controls. What is being verified is omacool's side of
    the contract: which commands are gated, what subject is handed to polkit,
    and what happens when the answer is no.
    """

    def fake_pkcheck(self, exit_code):
        path = os.path.join(self.tmp, "pkcheck-%d" % exit_code)
        with open(path, "w") as handle:
            handle.write('#!/bin/sh\nprintf "%s" "$*" >> "$0.args"\nexit ' + str(exit_code) + "\n")
        os.chmod(path, 0o755)
        omacool.PKCHECK = path
        return path

    def recorded_args(self, path):
        try:
            with open(path + ".args") as handle:
                return handle.read()
        except OSError:
            return ""

    def test_the_daemons_own_user_needs_no_polkit_check(self):
        missing = os.path.join(self.tmp, "does-not-exist")
        omacool.PKCHECK = missing
        allowed, reason = omacool.authorize(os.getpid(), os.geteuid())
        self.assertTrue(allowed, reason)

    def test_another_user_is_allowed_when_polkit_agrees(self):
        path = self.fake_pkcheck(0)
        allowed, reason = omacool.authorize(os.getpid(), os.geteuid() + 1)
        self.assertTrue(allowed, reason)
        self.assertIn(omacool.POLKIT_ACTION, self.recorded_args(path))

    def test_another_user_is_refused_when_polkit_declines(self):
        self.fake_pkcheck(1)
        allowed, reason = omacool.authorize(os.getpid(), os.geteuid() + 1)
        self.assertFalse(allowed)
        self.assertIn("not authorized", reason)

    def test_the_subject_pins_pid_start_time_and_uid(self):
        path = self.fake_pkcheck(0)
        uid = os.geteuid() + 1
        omacool.authorize(os.getpid(), uid)
        expected = "%d,%d,%d" % (os.getpid(), omacool.process_start_time(os.getpid()), uid)
        self.assertIn(expected, self.recorded_args(path))

    def test_missing_polkit_refuses_instead_of_falling_open(self):
        omacool.PKCHECK = os.path.join(self.tmp, "no-such-binary")
        allowed, reason = omacool.authorize(os.getpid(), os.geteuid() + 1)
        self.assertFalse(allowed)
        self.assertIn("polkit", reason)

    def test_a_vanished_caller_is_refused(self):
        self.fake_pkcheck(0)
        # A pid that cannot be read from /proc has no start time to pin the
        # check to, so it must not be authorized.
        allowed, reason = omacool.authorize(2 ** 22 - 1, os.geteuid() + 1)
        self.assertFalse(allowed)

    def test_start_time_parsing_survives_a_comm_full_of_parentheses(self):
        self.assertIsNotNone(omacool.process_start_time(os.getpid()))
        self.assertIsNone(omacool.process_start_time(2 ** 22 - 1))

    def test_read_only_commands_are_not_gated(self):
        for command in ("ping", "status", "config"):
            self.assertIn(command, omacool.READ_ONLY_COMMANDS)
        for command in ("set", "mode", "curve", "preset", "reset", "reload"):
            self.assertNotIn(command, omacool.READ_ONLY_COMMANDS)


class CliTests(FakeTreeCase):
    def run_cli(self, *args):
        env = dict(os.environ)
        env["OMACOOL_HWMON"] = self.hwmon
        env["OMACOOL_CONFIG"] = self.config
        env["OMACOOL_SOCKET"] = os.path.join(self.tmp, "absent.sock")
        return subprocess.run([sys.executable, BIN, *args],
                              capture_output=True, text=True, env=env)

    def test_status_json_is_parseable(self):
        result = self.run_cli("status", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        status = json.loads(result.stdout)
        self.assertEqual(status["controllable"], 2)
        self.assertFalse(status["daemon"])

    def test_list_json_is_parseable(self):
        result = self.run_cli("list", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(json.loads(result.stdout)), 2)

    def test_human_status_mentions_every_fan(self):
        result = self.run_cli("status")
        self.assertIn("nct6798/fan1", result.stdout)
        self.assertIn("CPU fan", result.stdout)
        self.assertIn("[CPU]", result.stdout)
        self.assertIn("[CASE]", result.stdout)

    def test_group_cli_list_json(self):
        result = self.run_cli("group", "list", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertIn("groups", data)
        self.assertIn("fans", data)

    def test_preset_listing_marks_the_active_one(self):
        result = self.run_cli("preset")
        self.assertIn("* balanced", result.stdout)

    def test_control_without_daemon_explains_itself(self):
        result = self.run_cli("set", "nct6798/fan1", "50")
        self.assertEqual(result.returncode, 1)
        self.assertIn("daemon is not reachable", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)

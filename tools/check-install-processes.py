#!/usr/bin/env python3
"""Process fixtures only: never inspect, signal, launch, or quit a real app."""

import importlib.util
from pathlib import Path
import signal
import unittest


spec = importlib.util.spec_from_file_location("app_processes", Path(__file__).with_name("app_processes.py"))
processes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(processes)


class InstallProcessTests(unittest.TestCase):
    target = "/Applications/DisplayMind.app"

    def command(self, target=None, arguments=""):
        return (target or self.target) + "/Contents/MacOS/DisplayMind" + arguments

    def test_matches_only_the_installed_gui_executable(self):
        for command in [self.command(), self.command(arguments=" -psn_0_12345"), "  " + self.command() + "  "]:
            with self.subTest(command=command):
                self.assertTrue(processes.is_installed_gui(command, self.target))
        for command in [
            self.command("/Users/example/GIT/DisplayMind/dist/DisplayMind.app"),
            self.command("/Applications/Another DisplayMind.app"),
            self.command() + "-preview",
            "DisplayMind",
            "",
        ]:
            with self.subTest(command=command):
                self.assertFalse(processes.is_installed_gui(command, self.target))

    def test_all_headless_modes_are_excluded_at_the_installed_path(self):
        for mode in ["--render-preview", "--watchdog", "--diagnostics", "--airplay-probe", "--airplay-connect", "--airplay-disconnect", "--airplay-access-status"]:
            for arguments in [f" {mode} /tmp/fixture", f" -psn_0_123 {mode} /tmp/fixture", f" {mode}=/tmp/fixture"]:
                with self.subTest(arguments=arguments):
                    self.assertFalse(processes.is_installed_gui(self.command(arguments=arguments), self.target))

    def test_synthetic_show_windows_are_not_installed_gui_instances(self):
        self.assertFalse(processes.is_installed_gui(self.command(arguments=" --render-preview /tmp/preview.png --show"), self.target))

    def test_paths_with_spaces_are_matched_without_shell_parsing(self):
        target = "/Applications/Fixture Apps/DisplayMind.app"
        self.assertTrue(processes.is_installed_gui(self.command(target, " -psn_0_123"), target))
        self.assertFalse(processes.is_installed_gui(self.command(target, " --watchdog /tmp/Fixture State"), target))

    def test_mode_words_inside_paths_do_not_change_the_mode(self):
        self.assertTrue(processes.is_installed_gui(self.command(arguments=" /tmp/--watchdog.log"), self.target))

    def test_candidate_pid_parsing_ignores_invalid_and_duplicate_rows(self):
        self.assertEqual(processes.parse_pids("17\n 23 \n0\n17\n-1\nnot a pid\n"), [17, 23])

    def test_only_target_gui_pids_are_selected_from_process_fixtures(self):
        commands = {
            1: self.command(),
            2: self.command(arguments=" --watchdog /tmp/fixture"),
            3: self.command("/Users/example/GIT/DisplayMind/dist/DisplayMind.app", " --render-preview /tmp/fixture.png"),
            4: self.command(arguments=" --diagnostics"),
            5: "",
        }
        self.assertEqual(processes.matching_pids(self.target, commands, commands.__getitem__), [1])

    def test_termination_revalidates_each_pid_and_never_signals_headless_processes(self):
        reads = {1: iter([self.command(), self.command()]), 2: iter([self.command(), self.command(arguments=" --watchdog /tmp/fixture")]), 3: iter([self.command(arguments=" --render-preview /tmp/fixture.png")])}
        signals = []
        processes.terminate_matching(self.target, reads, lambda pid: next(reads[pid]), lambda pid, kind: signals.append((pid, kind)))
        self.assertEqual(signals, [(1, signal.SIGTERM)])

    def test_a_process_exiting_before_the_signal_is_harmless(self):
        def gone(pid, kind):
            raise ProcessLookupError()
        processes.terminate_matching(self.target, [1], lambda pid: self.command(), gone)


if __name__ == "__main__":
    unittest.main()

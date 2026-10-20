"""The existing color command explains how a color affects a group's status."""
import os
import subprocess
import unittest


class WorkspaceGroupColorHelpTests(unittest.TestCase):
    def test_set_color_help_explains_status_and_invalid_hex(self):
        cli = os.environ["CMUX_CLI_BIN"]  # The runner pins the exact tagged build.
        env = {key: value for key, value in os.environ.items() if not key.startswith("CMUX_")}
        env["CMUX_SOCKET_PATH"] = "/private/tmp/cm-110.2-help-no-socket.sock"
        result = subprocess.run([cli, "workspace-group", "set-color", "--help"],
                                env=env, text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        text = result.stdout.lower()
        self.assertIn("status's color sets that status", text)
        self.assertIn("any other color clears", text)
        self.assertIn("invalid hex is refused", text)


if __name__ == "__main__":
    unittest.main()

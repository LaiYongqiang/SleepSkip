#!/usr/bin/env python3
"""Real subprocess and PTY regression checks. Never invokes hooks, locks or pmset."""
import errno
import os
import pty
import select
import shlex
import signal
import subprocess
import time
import unittest

BINARY = os.path.abspath(os.environ.get('SLEEPSKIP_BINARY', '.build/debug/SleepSkip'))


def wait_for(predicate, timeout=4):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(.025)
    return False


def children(pid):
    result = subprocess.run(['/bin/ps', '-axo', 'pid=,ppid=,comm='], capture_output=True, text=True, check=True)
    return [(int(p), c) for line in result.stdout.splitlines() if len(parts := line.strip().split(None, 2)) == 3 for p, parent, c in [parts] if int(parent) == pid]


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


class CLITests(unittest.TestCase):
    def test_terminal_input_and_status(self):
        pid, fd = pty.fork()
        if pid == 0:
            os.execv(BINARY, [BINARY, '--', '/bin/sh', '-c', 'printf "READY\\n"; read value; printf "GOT:%s\\n" "$value"; exit 23'])
        output = bytearray()
        try:
            os.write(fd, b'hello-terminal\n')
            deadline = time.monotonic() + 4
            status = None
            while time.monotonic() < deadline:
                if select.select([fd], [], [], .05)[0]:
                    try:
                        output.extend(os.read(fd, 65536))
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise
                done, value = os.waitpid(pid, os.WNOHANG)
                if done:
                    status = os.waitstatus_to_exitcode(value)
                    break
            self.assertEqual(status, 23, output.decode(errors='replace'))
            self.assertIn(b'GOT:hello-terminal', output)
        finally:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
            os.close(fd)

    def test_terminal_ctrl_c(self):
        pid, fd = pty.fork()
        if pid == 0:
            os.execv(BINARY, [BINARY, '--', '/bin/sleep', '20'])
        try:
            time.sleep(.2)
            os.write(fd, b'\x03')
            result = []
            def exited():
                # Drain PTY output while waiting: macOS terminal close may await output.
                if select.select([fd], [], [], 0)[0]:
                    try:
                        os.read(fd, 65536)
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise
                p, s = os.waitpid(pid, os.WNOHANG)
                if p:
                    result.append(os.waitstatus_to_exitcode(s))
                return bool(p)
            self.assertTrue(wait_for(exited), 'Ctrl-C did not exit wrapper')
            self.assertEqual(result, [130])
        finally:
            try:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            except (ProcessLookupError, ChildProcessError):
                pass
            os.close(fd)

    def test_command_preserves_arguments_environment_and_signals(self):
        env = dict(os.environ, SLEEPSKIP_CLI_CHECK='kept')
        result = subprocess.run([BINARY, '--', '/bin/sh', '-c', 'printf "%s|%s" "$SLEEPSKIP_CLI_CHECK" "$1"; exit 17', 'test', 'space $ &'], env=env, capture_output=True, timeout=4)
        self.assertEqual(result.returncode, 17)
        self.assertEqual(result.stdout, b'kept|space $ &')
        result = subprocess.run([BINARY, '--', '/bin/sh', '-c', 'kill -TERM $$'], capture_output=True, timeout=4)
        self.assertEqual(result.returncode, 143)

    def check_watch_signal(self, sig):
        target = subprocess.Popen(['/bin/sleep', '20'])
        watcher = subprocess.Popen([BINARY, 'watch', str(target.pid)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        cafes = []
        try:
            self.assertTrue(wait_for(lambda: bool(children(watcher.pid))))
            cafes = [p for p, c in children(watcher.pid) if c.endswith('caffeinate')]
            self.assertEqual(len(cafes), 1)
            watcher.send_signal(sig)
            watcher.wait(timeout=4)
            self.assertTrue(wait_for(lambda: all(not alive(p) for p in cafes)), f'caffeinate leaked after signal {sig}: {cafes}')
            self.assertIsNone(target.poll(), 'watch cancellation killed target')
            if sig != signal.SIGKILL:
                self.assertEqual(watcher.returncode, 128 + sig)
        finally:
            for p in cafes:
                try:
                    os.kill(p, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            for task in (watcher, target):
                if task.poll() is None:
                    task.kill()
                task.wait()
            if watcher.stderr:
                watcher.stderr.close()

    def test_watch_sigint_releases_assertion(self):
        self.check_watch_signal(signal.SIGINT)

    def test_watch_sigterm_releases_assertion(self):
        self.check_watch_signal(signal.SIGTERM)

    def test_watch_sigkill_releases_assertion(self):
        self.check_watch_signal(signal.SIGKILL)

    def test_command_sigkill_releases_assertion(self):
        wrapper = subprocess.Popen([BINARY, '--', '/bin/sleep', '20'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        owned = []
        try:
            self.assertTrue(wait_for(lambda: len(children(wrapper.pid)) == 2))
            owned = children(wrapper.pid)
            cafes = [p for p, c in owned if c.endswith('caffeinate')]
            self.assertEqual(len(cafes), 1)
            wrapper.kill()
            wrapper.wait(timeout=4)
            self.assertTrue(wait_for(lambda: all(not alive(p) for p in cafes)), 'command wrapper leaked assertion')
        finally:
            for p, _ in owned:
                try:
                    os.kill(p, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            if wrapper.poll() is None:
                wrapper.kill()
            wrapper.wait()

    def test_terminal_stop_resume_and_ownership(self):
        pid, fd = pty.fork()
        if pid == 0:
            os.execv(BINARY, [BINARY, '--', '/bin/sh', '-c', 'printf "READY\\n"; read value; printf "RESUMED:%s\\n" "$value"'])
        try:
            time.sleep(.2)
            os.write(fd, b'\x1a')
            states = []
            def stopped():
                p, state = os.waitpid(pid, os.WNOHANG | os.WUNTRACED)
                if p:
                    states.append(state)
                return bool(p)
            self.assertTrue(wait_for(stopped), 'Ctrl-Z did not stop wrapper')
            self.assertTrue(os.WIFSTOPPED(states[0]))
            self.assertEqual(os.tcgetpgrp(fd), pid, 'terminal not restored while stopped')
            os.kill(pid, signal.SIGCONT)
            os.write(fd, b'resumed-input\n')
            output = bytearray()
            result = []
            deadline = time.monotonic() + 4
            while time.monotonic() < deadline:
                if select.select([fd], [], [], .05)[0]:
                    try:
                        output.extend(os.read(fd, 65536))
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise
                done, state = os.waitpid(pid, os.WNOHANG)
                if done:
                    result.append(os.waitstatus_to_exitcode(state))
                    break
            self.assertEqual(result, [0], output.decode(errors='replace'))
            self.assertIn(b'RESUMED:resumed-input', output)
        finally:
            try:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            except (ProcessLookupError, ChildProcessError):
                pass
            os.close(fd)

    def test_terminal_input_with_redirected_stdin(self):
        pid, fd = pty.fork()
        if pid == 0:
            null = os.open('/dev/null', os.O_RDONLY)
            os.dup2(null, 0)
            os.close(null)
            os.execv(BINARY, [BINARY, '--', '/bin/sh', '-c', 'read value < /dev/tty; printf "TTY:%s\\n" "$value"'])
        try:
            os.write(fd, b'controlling-terminal\n')
            output = bytearray()
            result = []
            deadline = time.monotonic() + 4
            while time.monotonic() < deadline:
                if select.select([fd], [], [], .05)[0]:
                    try:
                        output.extend(os.read(fd, 65536))
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise
                done, state = os.waitpid(pid, os.WNOHANG)
                if done:
                    result.append(os.waitstatus_to_exitcode(state))
                    break
            self.assertEqual(result, [0], output.decode(errors='replace'))
            self.assertIn(b'TTY:controlling-terminal', output)
        finally:
            try:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            except (ProcessLookupError, ChildProcessError):
                pass
            os.close(fd)

    def check_shell_job_control(self, initially_background):
        shell, fd = pty.fork()
        if shell == 0:
            os.environ['PS1'] = 'SS_PROMPT> '
            os.execv('/bin/bash', ['bash', '--noprofile', '--norc', '-i'])
        output = bytearray()
        cursor = 0
        def receive(marker, timeout=4):
            nonlocal cursor
            end = time.monotonic() + timeout
            while time.monotonic() < end:
                found = output.find(marker, cursor)
                if found >= 0:
                    cursor = found + len(marker)
                    return
                if select.select([fd], [], [], .05)[0]:
                    try:
                        output.extend(os.read(fd, 65536))
                    except OSError as error:
                        if error.errno == errno.EIO:
                            break
                        raise
            self.fail('Missing %r: %s' % (marker, output.decode(errors='replace')))
        try:
            receive(b'SS_PROMPT> ')
            command = shlex.quote(BINARY) + ' -- /bin/sh -c ' + shlex.quote('printf "READY\\n"; read value; printf "GOT:%s\\n" "$value"')
            os.write(fd, (command + (' &\n' if initially_background else '\n')).encode())
            receive(b'READY\r\n')
            if initially_background:
                # Bash may defer a background-job notification until the next prompt.
                # Observe the actual stopped wrapper, not notification timing.
                def background_stopped():
                    for child, _ in children(shell):
                        state = subprocess.run(['/bin/ps', '-p', str(child), '-o', 'stat='], capture_output=True, text=True).stdout
                        if 'T' in state:
                            return True
                    return False
                self.assertTrue(wait_for(background_stopped), 'background terminal reader did not stop')
            else:
                os.write(fd, b'\x1a')
                receive(b'Stopped')
                os.write(fd, b'bg\n')
                # A background terminal reader may stop again; it must never take the tty.
                time.sleep(.2)
                self.assertEqual(os.tcgetpgrp(fd), shell, 'bg stole terminal from invoking shell')
            os.write(fd, b'fg\n')
            self.assertTrue(wait_for(lambda: os.tcgetpgrp(fd) != shell), 'fg did not transfer terminal')
            os.write(fd, b'shell-job-input\n')
            receive(b'GOT:shell-job-input')
            self.assertTrue(wait_for(lambda: os.tcgetpgrp(fd) == shell), 'terminal not restored to shell')
        finally:
            # The PTY is a new session. Only clean up jobs belonging to this test shell.
            rows = subprocess.run(['/bin/ps', '-axo', 'pid=,ppid=,pgid=,comm='], capture_output=True, text=True).stdout.splitlines()
            owned = {shell}
            processes = []
            for row in rows:
                fields = row.split(None, 3)
                if len(fields) == 4:
                    processes.append(tuple(map(int, fields[:3])))
            for _ in range(4):
                owned.update(pid for pid, parent, _ in processes if parent in owned)
            for pid in sorted(owned, reverse=True):
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            # macOS can wait for pending terminal output during session teardown.
            # Drain the PTY while reaping rather than blocking with no reader.
            end = time.monotonic() + 4
            while time.monotonic() < end:
                if select.select([fd], [], [], .025)[0]:
                    try:
                        os.read(fd, 65536)
                    except OSError:
                        pass
                try:
                    done, _ = os.waitpid(shell, os.WNOHANG)
                    if done:
                        break
                except ChildProcessError:
                    break
            os.close(fd)

    def test_shell_background_job_can_be_foregrounded(self):
        self.check_shell_job_control(initially_background=True)

    def test_shell_bg_does_not_steal_terminal(self):
        self.check_shell_job_control(initially_background=False)

    def test_watch_target_exit(self):
        target = subprocess.Popen(['/bin/sleep', '.25'])
        try:
            watcher = subprocess.run([BINARY, 'watch', str(target.pid)], capture_output=True, timeout=4)
            self.assertEqual(watcher.returncode, 0, watcher.stderr)
        finally:
            target.wait()


if __name__ == '__main__':
    unittest.main()

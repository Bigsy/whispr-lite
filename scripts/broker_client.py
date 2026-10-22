"""Small line-protocol client for the synthetic broker tests and media probe."""

import json
import queue
import subprocess
import threading
import time


class BrokerClient:
    def __init__(self, process, on_event=None):
        self.process = process
        self.events = queue.Queue()
        self.generation = None

        def read():
            for line in process.stdout:
                try:
                    event = json.loads(line)
                except ValueError:
                    event = {'type': 'invalid'}
                if event.get('type') == 'ready':
                    self.generation = event['generation']
                if on_event is not None:
                    on_event(event)
                self.events.put(event)

        self.thread = threading.Thread(target=read, daemon=True)
        self.thread.start()

    def wait(self, kind, request=None, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                event = self.events.get(timeout=max(.001, deadline - time.monotonic()))
            except queue.Empty:
                break
            if event.get('type') == kind and (request is None or event.get('request') == request):
                return event
        raise RuntimeError('Media response deadline')

    def send(self, operation, session='', deadline_ms=500, **extra):
        request = str(time.monotonic_ns())
        body = dict(version=1, operation=operation, generation=self.generation,
                    request=request, session=session, deadlineMS=deadline_ms)
        body.update(extra)
        self.process.stdin.write(json.dumps(body).encode() + b'\n')
        self.process.stdin.flush()
        return request

    def close(self):
        if not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=2)
        self.thread.join(timeout=1)
        if not self.process.stdout.closed:
            self.process.stdout.close()

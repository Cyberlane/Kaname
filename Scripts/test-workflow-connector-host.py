#!/usr/bin/env python3
"""Exercise the built connector host against private local socket fixtures."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading


def invoke(binary, path, mode="dispatch"):
    environment = os.environ.copy()
    environment.pop("KANAME_WORKFLOW_CONNECTOR_SOCKET", None)
    if path is not None:
        environment["KANAME_WORKFLOW_CONNECTOR_SOCKET"] = str(path)
    result = subprocess.run(
        [str(binary), mode], input='{"action":"archive"}',
        text=True, capture_output=True, env=environment, timeout=10, check=True,
    )
    return json.loads(result.stdout)


def exchange(binary, path, response):
    observed = []
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
        listener.bind(str(path))
        listener.listen(1)
        listener.settimeout(5)

        def serve():
            client, _ = listener.accept()
            with client:
                client.settimeout(5)
                request = b""
                while not request.endswith(b"\n"):
                    data = client.recv(4096)
                    if not data:
                        break
                    request += data
                observed.append(json.loads(request))
                if response is not None:
                    client.sendall(response)

        thread = threading.Thread(target=serve)
        thread.start()
        result = invoke(binary, path)
        thread.join(timeout=6)
        assert not thread.is_alive(), "fixture did not finish"
    path.unlink()
    assert observed == [{"mode": "dispatch", "request": {"action": "archive"}}]
    return result


def main():
    binary = Path(sys.argv[1]).resolve(strict=True)
    assert invoke(binary, None, "describe") == {"connectors": []}
    assert invoke(binary, "relative.sock")["outcome"] == "not_sent"
    with tempfile.TemporaryDirectory(prefix="kaname-host-", dir="/private/tmp") as root:
        path = Path(root) / "bridge.sock"
        assert invoke(binary, path)["outcome"] == "not_sent"
        expected = {"outcome": "applied", "fixture": "exact-channel"}
        assert exchange(binary, path, json.dumps(expected).encode() + b"\n") == expected
        assert exchange(binary, path, None)["outcome"] == "outcome_unknown"
        assert exchange(binary, path, b"invalid-json\n")["outcome"] == "outcome_unknown"
    print("Connector host: exact socket and uncertain transport fixtures passed")


if __name__ == "__main__":
    main()

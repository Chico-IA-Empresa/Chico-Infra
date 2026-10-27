"""Build allowlisted CloudWatch events; raw proxy fields never leave this process."""
import json
import math
import os
import pathlib
import sys
import time

METHODS = {"GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "CONNECT", "TRACE"}


def sanitize(record):
    try:
        status, duration, size = record["status"], record["duration"], record["size"]
        method = record.get("request", {}).get("method")
        if type(status) is not int or not 100 <= status <= 599:
            raise ValueError()
        if type(size) is not int or size < 0:
            raise ValueError()
        if type(duration) not in (int, float) or not math.isfinite(duration) or duration < 0:
            raise ValueError()
        return {"type": "proxy_access", "method": method if method in METHODS else "OTHER", "status": status, "duration": duration, "size": size}
    except (KeyError, TypeError, ValueError, AttributeError):
        return {"type": "proxy_record_rejected"}


def read_events(path, cursor=None, now_ms=None):
    cursor = cursor or {}
    timestamp = int(time.time() * 1000) if now_ms is None else now_ms
    events = []
    with open(path, "rb") as stream:
        stat = os.fstat(stream.fileno())
        same_file = cursor.get("inode") == stat.st_ino and cursor.get("device") == stat.st_dev
        offset = cursor.get("offset", 0) if same_file else 0
        if type(offset) is not int or not 0 <= offset <= stat.st_size:
            offset = 0
        stream.seek(offset)
        for _ in range(100):
            start = stream.tell()
            line = stream.readline(65537)
            if not line:
                break
            if not line.endswith(b"\n") and len(line) <= 65536:
                stream.seek(start)  # leave a partial write for the next poll
                break
            try:
                safe = sanitize(json.loads(line)) if len(line) <= 65536 else {"type": "proxy_record_rejected"}
            except (ValueError, UnicodeError):
                safe = {"type": "proxy_record_rejected"}
            events.append({"timestamp": timestamp, "message": json.dumps(safe, separators=(",", ":"))})
        return {"events": events, "cursor": {"offset": stream.tell(), "inode": stat.st_ino, "device": stat.st_dev}}


if __name__ == "__main__":
    try:
        cursor_file = pathlib.Path(sys.argv[2])
        cursor = json.loads(cursor_file.read_text()) if cursor_file.exists() else None
        print(json.dumps(read_events(sys.argv[1], cursor)))
    except Exception:
        print("Proxy event preparation failed", file=sys.stderr)
        sys.exit(1)

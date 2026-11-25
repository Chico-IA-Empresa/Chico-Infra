"""Private synthetic delivery and persistent file consumer. No value logging.

The supplied asm-exec main resolves argv only. Call its pinned resolver in this
process so plaintext never becomes an argument or a container environment value.
"""
import argparse
import contextlib
import hashlib
import hmac
import io
import json
import os
import pathlib
import re
import stat
import sys

REFERENCE = "{{resolve:secretsmanager:/chico/dev/api/SYNTHETIC_TOKEN}}"
RESOLVER_PATH = pathlib.Path("/usr/local/bin/asm-exec")
DELIVERY_ROOT = pathlib.Path("/run/chico/api")
RESOLVER_SHA256 = "38399ce2a9a2b5e69fc9179815d90669e80612ea1dfc4dc2d399db9608488035"
MAX_TOKEN_BYTES = 4096


def validate(value):
    if not isinstance(value, str) or not value or "{{resolve:" in value:
        raise ValueError("Resolution missing")
    if len(value.encode("utf-8")) > MAX_TOKEN_BYTES or "\x00" in value:
        raise ValueError("Token rejected")
    return value


def private_directory(directory):
    """Refuse symlink parents; do not chmod existing paths."""
    directory = pathlib.Path(directory)
    for parent in (directory, *directory.parents):
        if parent.is_symlink():
            raise ValueError("Symlink refused")
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not directory.is_dir():
        raise ValueError("Directory required")
    if os.name == "posix":
        info = directory.stat()
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError("Private directory required")


def consume(value, destination):
    """Create a per-launch file, never truncate an earlier launch."""
    value = validate(value)
    destination = pathlib.Path(destination)
    private_directory(destination.parent)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(destination, flags, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as stream:
            if hasattr(os, "fchmod"):
                os.fchmod(stream.fileno(), 0o600)
            stream.write(value)
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        destination.unlink(missing_ok=True)
        raise


def read_private(path):
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError("Private regular file required")
        if os.name == "posix" and (stat.S_IMODE(info.st_mode) != 0o600 or info.st_uid != os.geteuid()):
            raise ValueError("Private file ownership/mode required")
        data = stream.read(MAX_TOKEN_BYTES + 1)
        if len(data) > MAX_TOKEN_BYTES:
            raise ValueError("Token rejected")
        return validate(data.decode("utf-8"))


class PersistentConsumer:
    def __init__(self, path):
        self._value = read_private(path)

    def matches(self, candidate):
        return hmac.compare_digest(self._value.encode("utf-8"), validate(candidate).encode("utf-8"))


def serve(path, input_stream, output_stream):
    consumer = PersistentConsumer(path)  # Exactly one read at launch.
    print('{"ready":true}', file=output_stream, flush=True)
    while True:
        line = input_stream.readline(32769)
        if not line:
            return
        if len(line) > 32768 or not line.endswith("\n"):
            raise ValueError("Protocol rejected")
        request = json.loads(line)
        if not isinstance(request, dict) or set(request) != {"candidate"}:
            raise ValueError("Protocol rejected")
        print(json.dumps({"matches": consumer.matches(request["candidate"])}), file=output_stream, flush=True)


def load_resolver(path=RESOLVER_PATH):
    """Load only the exact reviewed executable; never invoke its argv main."""
    path = pathlib.Path(path)
    for item in (path, *path.parents):
        info = item.lstat()
        if stat.S_ISLNK(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise ValueError("Untrusted resolver path")
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(descriptor, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("Resolver file required")
        source = stream.read(1024 * 1024)
    if hashlib.sha256(source).hexdigest() != RESOLVER_SHA256:
        raise ValueError("Resolver pin mismatch")
    namespace = {"__name__": "chico_pinned_asm_resolver", "__file__": str(path)}
    exec(compile(source, str(path), "exec"), namespace)
    if not callable(namespace.get("resolve_string")):
        raise ValueError("Resolver interface missing")
    return namespace["resolve_string"]


def require_tmpfs(path):
    path = pathlib.PurePosixPath(str(path))
    mounts = {}
    matches = {}
    for line in pathlib.Path("/proc/self/mountinfo").read_text().splitlines():
        fields = line.split()
        separator = fields.index("-")
        mount = pathlib.PurePosixPath(fields[4].replace("\\040", " ").replace("\\134", "\\"))
        mount_id, parent_id = int(fields[0]), int(fields[1])
        if mount_id in mounts:
            raise ValueError("Ambiguous mount graph")
        mounts[mount_id] = (parent_id, fields[separator + 1], mount)
        if path == mount or mount in path.parents:
            # Stacked mounts at the same path have visibility ordering that
            # cannot be inferred from depth or filesystem spelling. Refuse all
            # such ambiguities, including overmounts on an ancestor of target.
            if mount in matches:
                raise ValueError("Stacked ancestor mount refused")
            matches[mount] = mount_id
    if not matches:
        raise ValueError("tmpfs required")
    selected = matches[max(matches, key=lambda mount: len(mount.parts))]
    # A deeper lexical match can belong to a hidden subtree of an overmounted
    # ancestor. Every matching ancestor must be on the selected mount's actual
    # parent chain; otherwise the deepest path does not establish visibility.
    chain = set()
    cursor = selected
    while cursor in mounts:
        if cursor in chain:
            raise ValueError("Cyclic mount graph")
        chain.add(cursor)
        parent_id, _, mount = mounts[cursor]
        # A namespace root may legitimately name itself as its parent. Only
        # that '/' terminal is accepted; self-parent children and real cycles
        # continue through the loop and are refused.
        if parent_id == cursor and mount == pathlib.PurePosixPath("/"):
            break
        cursor = parent_id
    if not set(matches.values()).issubset(chain) or mounts[selected][1] != "tmpfs":
        raise ValueError("Visible tmpfs required")


def deliver(launch_id):
    if sys.platform != "linux" or os.geteuid() != 0 or os.environ.get("CHICO_SYNTHETIC_ONLY") != "true":
        raise ValueError("Approved Linux root fixture required")
    if not re.fullmatch(r"[a-f0-9]{32}", launch_id):
        raise ValueError("Launch identifier rejected")
    if os.environ.get("AWS_REGION") != "sa-east-1":
        raise ValueError("Region required")
    if os.environ.get("ASM_EXEC_MCP_ENDPOINT") or os.environ.get("AWS_SECRETS_MANAGER_AGENT_ENDPOINT"):
        raise ValueError("Resolver endpoint override refused")
    root = DELIVERY_ROOT
    require_tmpfs(root)
    private_directory(root)
    target = root / launch_id / "synthetic_token"
    if target.parent.exists() or target.parent.is_symlink():
        raise ValueError("Existing launch refused")
    resolver = load_resolver()
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        value = resolver(REFERENCE)
    consume(value, target)
    print(json.dumps({"delivered": True, "launchId": launch_id}))


def main():
    parser = argparse.ArgumentParser(description="Synthetic private file consumer")
    sub = parser.add_subparsers(dest="operation", required=True)
    delivery = sub.add_parser("deliver")
    delivery.add_argument("--launch-id", required=True)
    server = sub.add_parser("serve")
    server.add_argument("--token-file", required=True)
    args = parser.parse_args()
    try:
        if args.operation == "deliver":
            deliver(args.launch_id)
        else:
            serve(args.token_file, sys.stdin, sys.stdout)
    except (Exception, SystemExit):
        print('{"error":"synthetic_configuration_failed"}', file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

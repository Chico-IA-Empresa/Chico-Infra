"""Invoked only by asm-exec; never logs argument values. No AWS SDK calls."""
import os
import pathlib
import sys


def consume(value, destination):
    if not value or value.startswith("{{resolve:"):
        raise ValueError("Runtime resolution missing")
    # This executable is installed root-owned; fixed /run path, no caller filename.
    directory = pathlib.Path(destination).parent
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    if directory.is_symlink() or pathlib.Path(destination).is_symlink():
        raise ValueError("Symlink refused")
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(descriptor, "w") as stream:
        if hasattr(os, "fchmod"):
            os.fchmod(stream.fileno(), 0o600)
        stream.write(value)


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("One resolved synthetic value required")
        consume(sys.argv[1], "/run/chico/api/synthetic_token")
        print("Synthetic consumer configuration refreshed")
    except Exception:
        print("Synthetic consumer configuration failed", file=sys.stderr)
        sys.exit(1)

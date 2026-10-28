"""Docker argv for the reviewed nonroot/offline restore toolchain; no execution on import."""
import re
from pathlib import Path

TARGETS = {"/repo": True, "/config": True, "/scripts": True,
           "/pgdata": False, "/evidence": False, "/work": False}


def isolated_command(image, uid, mounts, entrypoint, arguments):
    if not re.fullmatch(r"(?:[a-zA-Z0-9./:_-]+@)?sha256:[0-9a-f]{64}", image):
        raise ValueError("Immutable local image id or registry digest required")
    if type(uid) is not int or uid <= 0:
        raise ValueError("Nonroot numeric image UID required")
    if entrypoint not in {"/bin/bash", "/usr/bin/id", "/usr/local/bin/pgbackrest", "/usr/bin/python3"}:
        raise ValueError("Unreviewed entrypoint")
    argv = ["docker", "run", "--rm", "--network=none", "--read-only", "--cap-drop=ALL",
            "--security-opt=no-new-privileges", "--user", str(uid), "--pids-limit=256",
            "--memory=1536m", "--cpus=2", "--env", "LC_ALL=C", "--env", "TZ=UTC"]
    for target in ("/tmp", "/run", "/var/lib/postgresql/data"):
        argv += ["--tmpfs", f"{target}:rw,noexec,nosuid,nodev,uid={uid},mode=0700,size=128m"]
    for target, source in mounts.items():
        if target not in TARGETS:
            raise ValueError("Unreviewed mount destination")
        source = Path(source)
        if (not source.is_absolute() or not source.exists() or source.resolve() != source or
                "," in str(source) or "\n" in str(source)):
            raise ValueError("Existing canonical mount source required")
        argv += ["--mount", f"type=bind,src={source},dst={target}" + (",readonly" if TARGETS[target] else "")]
    return argv + ["--entrypoint", entrypoint, image, *arguments]

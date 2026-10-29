"""Docker argv for the reviewed nonroot/offline restore toolchain; no execution on import."""
import re
from pathlib import Path

TARGETS = {"/repo": True, "/config": True, "/scripts": True, "/control": True,
           "/pgdata": False, "/evidence": False, "/work": False}
POSTGRES_ENTRYPOINT = "/usr/lib/postgresql/16/bin/postgres"
POSTGRES_ARGUMENTS = ["-D", "/pgdata", "-c", "config_file=/scripts/clone/postgresql.conf"]
POSTGRES_TARGETS = {"/pgdata": False, "/repo": True, "/config": True, "/scripts/clone": True}


def isolated_command(image, uid, mounts, entrypoint, arguments):
    if not re.fullmatch(r"(?:[a-zA-Z0-9./:_-]+@)?sha256:[0-9a-f]{64}", image):
        raise ValueError("Immutable local image id or registry digest required")
    if type(uid) is not int or uid <= 0:
        raise ValueError("Nonroot numeric image UID required")
    if entrypoint not in {"/bin/bash", "/usr/bin/id", "/usr/local/bin/pgbackrest", POSTGRES_ENTRYPOINT}:
        raise ValueError("Unreviewed entrypoint")
    targets = TARGETS
    if entrypoint == POSTGRES_ENTRYPOINT:
        if uid != 999 or arguments != POSTGRES_ARGUMENTS or set(mounts) != set(POSTGRES_TARGETS):
            raise ValueError("Exact PostgreSQL16 clone command, identity, and mounts required")
        targets = POSTGRES_TARGETS
        for target, source in mounts.items():
            path = Path(source)
            if (target == "/config" and not path.is_file()) or (target != "/config" and not path.is_dir()):
                raise ValueError("Clone configuration must be one file; data/repository/templates must be directories")
    argv = ["docker", "run", "--rm", "--network=none", "--read-only", "--cap-drop=ALL",
            "--security-opt=no-new-privileges", "--user", str(uid), "--pids-limit=256",
            "--memory=1536m", "--cpus=2", "--env", "LC_ALL=C", "--env", "TZ=UTC"]
    for target in ("/tmp", "/run", "/var/lib/postgresql/data"):
        argv += ["--tmpfs", f"{target}:rw,noexec,nosuid,nodev,uid={uid},mode=0700,size=128m"]
    for target, source in mounts.items():
        if target not in targets:
            raise ValueError("Unreviewed mount destination")
        source = Path(source)
        if (not source.is_absolute() or not source.exists() or source.resolve() != source or
                "," in str(source) or "\n" in str(source)):
            raise ValueError("Existing canonical mount source required")
        argv += ["--mount", f"type=bind,src={source},dst={target}" + (",readonly" if targets[target] else "")]
    return argv + ["--entrypoint", entrypoint, image, *arguments]

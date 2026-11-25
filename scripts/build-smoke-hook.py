"""Empacota modules/api-deploy/smoke/handler.py em smoke.zip, de forma determinística.

O CI inicia o Terraform com lockfile somente leitura e só o provider aws, então
o zip da Lambda é versionado. Data fixa e permissões fixas: o mesmo fonte gera
sempre os mesmos bytes, e tests/api-smoke-hook.test.py reprova zip desatualizado.

uso: python scripts/build-smoke-hook.py [--check]
"""
import io
import pathlib
import sys
import zipfile

MODULE = pathlib.Path(__file__).resolve().parents[1] / "modules" / "api-deploy"
SOURCE = MODULE / "smoke" / "handler.py"
TARGET = MODULE / "smoke.zip"


def build() -> bytes:
    buffer = io.BytesIO()
    info = zipfile.ZipInfo("handler.py", date_time=(2026, 1, 1, 0, 0, 0))
    info.external_attr = 0o644 << 16
    info.compress_type = zipfile.ZIP_DEFLATED
    source = SOURCE.read_bytes().replace(b"\r\n", b"\n")
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr(info, source)
    return buffer.getvalue()


if __name__ == "__main__":
    data = build()
    if "--check" in sys.argv:
        if not TARGET.exists() or TARGET.read_bytes() != data:
            sys.exit("smoke.zip desatualizado: rode python scripts/build-smoke-hook.py")
        print("smoke.zip ok")
    else:
        TARGET.write_bytes(data)
        print(f"escrito {TARGET.relative_to(MODULE.parents[1])}")

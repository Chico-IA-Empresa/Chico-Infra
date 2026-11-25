"""Smoke do blue-green da API e do frontend no ECS (hook POST_TEST_TRAFFIC_SHIFT).

O ECS chama esta função depois de mandar o tráfego de TESTE para a cor nova. O
tráfego de teste é o que entra pela regra do ALB que exige o header
`TEST_HEADER: 1` (modules/alb); o tráfego real continua na cor antiga até a
função responder SUCCEEDED. FAILED faz o ECS desfazer o deploy.

Cada URL de SMOKE_URLS precisa responder 200; a de `/health/ready/release`
precisa ainda trazer `"status": "ready"` (Postgres, Valkey e LISTEN ok — o mesmo
gate de promoção do backend). Sem dependências fora da biblioteca padrão.
"""
import json
import os
import time
import urllib.error
import urllib.request

RELEASE_PATH = "/health/ready/release"


def check(url, header, timeout):
    request = urllib.request.Request(url, headers={header: "1", "User-Agent": "chico-deploy-smoke"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            status = response.status
            body = response.read(8192)
    except urllib.error.HTTPError as exc:
        return False, f"{url} HTTP {exc.code}"
    except Exception as exc:  # noqa: BLE001 - qualquer falha de rede reprova o smoke
        return False, f"{url} {type(exc).__name__}"
    if status != 200:
        return False, f"{url} HTTP {status}"
    if url.split("?", 1)[0].endswith(RELEASE_PATH):
        try:
            verdict = json.loads(body).get("status")
        except (ValueError, AttributeError):
            return False, f"{url} corpo não é JSON"
        if verdict != "ready":
            return False, f"{url} status={verdict}"
    return True, f"{url} ok"


def handler(event, context, sleep=time.sleep):
    urls = json.loads(os.environ["SMOKE_URLS"])
    header = os.environ.get("TEST_HEADER", "x-chico-deploy-test")
    attempts = max(int(os.environ.get("ATTEMPTS", "3")), 1)
    delay = float(os.environ.get("RETRY_DELAY_S", "5"))
    timeout = float(os.environ.get("REQUEST_TIMEOUT_S", "10"))
    results = []
    for url in urls:
        for attempt in range(attempts):
            ok, detail = check(url, header, timeout)
            if ok:
                break
            if attempt < attempts - 1:
                sleep(delay)
        results.append(detail)
        if not ok:
            print(json.dumps({"smoke": "failed", "results": results}))
            return {"hookStatus": "FAILED"}
    print(json.dumps({"smoke": "succeeded", "results": results}))
    return {"hookStatus": "SUCCEEDED"}

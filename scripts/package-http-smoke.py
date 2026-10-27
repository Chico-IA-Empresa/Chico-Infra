"""Fixture HTTP acceptance. Reads only explicitly mounted synthetic credentials.

No passwords, tokens, cookies, DSNs or response bodies are printed on failure.
"""
import asyncio
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import sys
import time


def main():
    import httpx
    import websockets
    root = os.environ.get('PACKAGE_HTTP_ORIGIN', 'http://proxy:8080').rstrip('/')
    if root not in {'http://proxy:8080', 'http://api:8000'}:
        raise ValueError('Only isolated fixture origin allowed')
    credential = json.loads(Path('/checks/seed.json').read_text())
    password = credential['DEV_SEED_PASSWORD']
    results = {}
    with httpx.Client(base_url=root, timeout=30, trust_env=False) as client:
        response = client.get('/api/health/ready' if '/proxy:' in root else '/health/ready')
        assert response.status_code == 200
        prefix = '/api' if '/proxy:' in root else ''
        response = client.post(prefix + '/auth/login', json={'email':'package@example.com', 'password':password})
        assert response.status_code == 200, 'fixture login failed'
        token = response.json()['access_token']
        refresh_cookie = client.cookies.get('chico_refresh')
        assert refresh_cookie
        cookie_header = response.headers.get('set-cookie', '').lower()
        assert 'httponly' in cookie_header and 'samesite=lax' in cookie_header and 'domain=' not in cookie_header
        results['loginAndHostOnlyCookie'] = True
        assert client.get(prefix + '/auth/me', headers={'Authorization':'Bearer '+token}).status_code == 200
        headers = {'Cookie':'chico_refresh='+refresh_cookie}
        def refresh(_):
            with httpx.Client(base_url=root, timeout=30, trust_env=False) as concurrent:
                response = concurrent.post(prefix+'/auth/refresh', headers=headers)
                assert response.status_code == 200
                assert response.json().get('access_token')
                return response.cookies.get('chico_refresh')
        with ThreadPoolExecutor(max_workers=2) as executor:
            rotated_cookies = list(executor.map(refresh, range(2)))
            assert all(rotated_cookies)
        results['concurrentRefresh'] = True
        # A core read uses the real seeded app/API, never a provider.
        detail = client.get(prefix + '/matches/package-v1-match', headers={'Authorization':'Bearer '+token})
        results['matchReadStatus'] = detail.status_code
        assert detail.status_code == 200, 'fixture match read failed'
        ws_root = root.replace('http://','ws://') + prefix + '/ws/odds?token=' + token
        async def websocket_smoke():
            for _ in range(2):  # close and reconnect using the same signed fixture token
                async with websockets.connect(ws_root, open_timeout=20, close_timeout=5) as socket:
                    await socket.ping()
                    from sqlalchemy import create_engine, text
                    engine = create_engine(credential['DATABASE_URL'], hide_parameters=True)
                    with engine.begin() as db:
                        db.execute(text("SELECT pg_notify('odds_changed', :payload)"),
                                   {'payload':json.dumps({'fixture_id':'package-v1-match'})})
                    engine.dispose()
                    ping = json.loads(await asyncio.wait_for(socket.recv(), timeout=20))
                    assert ping.get('type') == 'match_changed' and ping.get('fixtureId') == 'package-v1-match'
        asyncio.run(websocket_smoke())
        results['authenticatedWebsocketReconnect'] = True
        results['postgresListenNotifyFanout'] = True
        current_refresh = rotated_cookies[-1]
        assert client.post(prefix+'/auth/logout', headers={'Cookie':'chico_refresh='+current_refresh}).status_code == 200
        response = client.post(prefix+'/auth/refresh', headers={'Cookie':'chico_refresh='+current_refresh})
        assert response.status_code == 401
        results['logoutRevokesRefresh'] = True
    print(json.dumps({'scope':'real fixture HTTP/WS only; no providers', 'checks':results}))


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        import traceback
        frame = traceback.extract_tb(exc.__traceback__)[-1]
        print('HTTP fixture smoke failed: '+type(exc).__name__+' at '+Path(frame.filename).name+':'+str(frame.lineno), file=sys.stderr)
        sys.exit(1)

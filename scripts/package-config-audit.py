"""Names-only configuration audit. Parses Python; never imports application code.

The graph over-approximates static imports, including dormant code. Results are
review evidence, not an AWS grant or an automatically expanded runtime allowlist.
"""
import ast
import importlib.util
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
BACKEND = ROOT / 'backend'
ENTRYPOINTS = {
    'api': 'main', 'migrator': 'scripts.package_migrate', 'seed': 'scripts.package_seed',
    'odds-bsd': 'workers.worker_odds_bsd', 'odds-surebetting': 'workers.worker_odds_surebetting',
    'telegram-update': 'workers.telegram_update_worker', 'league-reports': 'workers.worker_league_reports',
    'match-analysis': 'workers.worker_match_analysis',
    **{name: 'workers.' + module for name, module in {
        'sofascore-match-list': 'sofascore_match_list_worker', 'sofascore-lineups': 'sofascore_lineups_worker',
        'sofascore-post-match-stats': 'sofascore_post_match_statistics_worker', 'sofascore-standings': 'sofascore_standings_worker',
        'sofascore-team-stats': 'sofascore_team_statistics_worker', 'sofascore-round-matches': 'sofascore_round_matches_worker'}.items()},
}
FINANCIAL = re.compile(r'ASAAS|MERCADOPAGO|PAYMENT|PAYOUT|BILLING|^INTER_|PIX|AFFILIATE')


def environment_names(node):
    """Read only constant argument names, never evaluate/default-export code."""
    result = set()
    for child in ast.walk(node):
        if isinstance(child, ast.Call) and child.args:
            function = child.func
            is_getenv = isinstance(function, ast.Attribute) and function.attr == 'getenv'
            is_environ_get = (isinstance(function, ast.Attribute) and function.attr == 'get'
                              and isinstance(function.value, ast.Attribute) and function.value.attr == 'environ')
            is_flag = isinstance(function, ast.Name) and function.id == '_env_flag'
            if is_getenv or is_environ_get or is_flag:
                arg = child.args[0]
                if isinstance(arg, ast.Constant) and isinstance(arg.value, str) and re.fullmatch('[A-Z][A-Z0-9_]*', arg.value):
                    result.add(arg.value)
        if isinstance(child, ast.Subscript) and isinstance(child.value, ast.Attribute) and child.value.attr == 'environ':
            arg = child.slice
            if isinstance(arg, ast.Constant) and isinstance(arg.value, str) and re.fullmatch('[A-Z][A-Z0-9_]*', arg.value):
                result.add(arg.value)
    return result


def source(module):
    path = BACKEND.joinpath(*module.split('.'))
    for candidate in (path.with_suffix('.py'), path / '__init__.py'):
        if candidate.is_file():
            return candidate
    return None


def imports(tree, path):
    package = list(path.relative_to(BACKEND).with_suffix('').parts)
    package.pop()  # __init__.py belongs to its containing package too.
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                yield alias.name
        elif isinstance(node, ast.ImportFrom):
            prefix = '.'.join(package[:len(package) - node.level + 1]) if node.level else ''
            module = '.'.join(filter(None, [prefix, node.module]))
            if module:
                yield module
                for alias in node.names:
                    if alias.name != '*':
                        yield module + '.' + alias.name


def audit():
    config_tree = ast.parse((BACKEND / 'core/config.py').read_text(encoding='utf-8'))
    fields = {}
    for node in ast.walk(config_tree):
        if isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            for target in targets:
                if isinstance(target, ast.Name):
                    fields[target.id] = environment_names(node)
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            fields[node.name] = environment_names(node)
    spec = importlib.util.spec_from_file_location('isolated_runtime_contract', BACKEND / 'core/package_runtime.py')
    contract = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(contract)  # This standalone file has no application imports.
    result = {}
    cache = {}
    for consumer, entrypoint in ENTRYPOINTS.items():
        pending, visited, uses = [entrypoint], set(), {}
        while pending:
            module = pending.pop()
            path = source(module)
            if path is None or path in visited:
                continue
            visited.add(path)
            # Python also executes each containing package's __init__ module.
            pending.extend('.'.join(module.split('.')[:i]) for i in range(1, len(module.split('.'))))
            # Settings definitions include all providers; do not attribute that
            # entire inventory to every consumer merely for importing Settings.
            if path == BACKEND / 'core/config.py':
                continue
            if path not in cache:
                cache[path] = ast.parse(path.read_text(encoding='utf-8-sig'))
            tree = cache[path]
            pending.extend(imports(tree, path))
            for node in ast.walk(tree):
                names = set()
                if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) and node.value.id == 'settings':
                    names |= fields.get(node.attr, set())
                if isinstance(node, (ast.Call, ast.Subscript)):
                    names |= environment_names(node)
                for name in names:
                    uses.setdefault(name, set()).add(f'{path.relative_to(BACKEND).as_posix()}:{node.lineno}')
        rows = []
        for name in sorted(set(uses) | contract.CONSUMERS[consumer]):
            policy = ('excluded-financial' if FINANCIAL.search(name) else
                      'injectable' if name in contract.CONSUMERS[consumer] else 'default-only-review-required')
            rows.append({'name': name, 'reference': f'/chico/<env>/{consumer}/{name}', 'policy': policy,
                         'sources': sorted(uses.get(name, set()))})
        result[consumer] = {'entrypoint': entrypoint, 'staticModules': len(visited), 'variables': rows}
    return {'version': 1, 'scope': 'static import over-approximation; names only; no environment loaded or default/provider values exported',
            'limitations': ['dynamic imports and runtime-only paths require execution evidence',
                           'dynamic environment names and aliased settings objects require manual review',
                           'barrel imports include dormant code; review-required rows are not approved injections',
                           'no helper/IAM/stores changed; financial variables excluded'], 'consumers': result}


if __name__ == '__main__':
    result = audit()
    path = ROOT / 'chico-infra/reports/package-configuration-audit.json'
    path.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'consumers': len(result['consumers']), 'nameConsumerRows': sum(len(v['variables']) for v in result['consumers'].values()),
                      'result': 'static evidence only; no runtime acceptance'}))

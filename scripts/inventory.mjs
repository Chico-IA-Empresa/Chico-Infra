import { readFileSync, writeFileSync, readdirSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join, relative } from 'node:path';
import { createHash } from 'node:crypto';
const root = fileURLToPath(new URL('../../', import.meta.url));
const out = join(root, 'chico-infra/reports'); mkdirSync(out, { recursive: true });
const hash = s => createHash('sha256').update(s).digest('hex');
const config = readFileSync(join(root, 'backend/core/config.py'), 'utf8');
const baseline = JSON.parse(readFileSync(join(root, 'ChicoIA-AWS/evidencias/2026-10-16/vps-baseline.json'), 'utf8'));
const names = [...new Set([...config.matchAll(/(?:getenv|environ\.get|_env_flag)\(\s*["']([A-Z][A-Z0-9_]+)["']/g)].map(m => m[1]))].sort();
const excluded = /^(ASAAS|MERCADOPAGO|INTER_|PIX_|PAYOUT_|AFFILIATE_|REFERRAL_|PAYMENT_|PAYMENTS_|SUBSCRIPTION_)/;
const envs = names.map(name => ({
  name,
  disposition: excluded.test(name) ? 'excluded-payment-target' : 'review-before-injection',
  store: /PASSWORD|SECRET|TOKEN|API_KEY|PRIVATE|CREDENTIAL|DSN|DATABASE_URL|REDIS_URL|CHAT_ID/.test(name) ? 'SecretsManager' : 'SSM-candidate-review-required',
  path: `/chico/<env>/<service>/${name}`,
  observedConsumers: baseline.containers.filter(c => (c.env_names ?? []).includes(name)).map(c => c.name),
  review: 'Confirmar consumidor no código, configuração de boot, sensibilidade e TLS; observação VPS de 16/10 não é allowlist de deploy.'
}));
writeFileSync(join(out, 'configuration-inventory.json'), JSON.stringify({ source: 'backend/core/config.py', sha256: hash(config), completeness: 'Candidates only; dynamic names and reads outside core/config.py need review', variables: envs }, null, 2));
const walk = dir => readdirSync(dir, { withFileTypes: true }).flatMap(d => d.isDirectory() ? walk(join(dir, d.name)) : d.name.endsWith('.py') ? [join(dir, d.name)] : []);
const columns = [];
for (const file of walk(join(root, 'backend/models'))) {
  const source = readFileSync(file, 'utf8');
  let table = 'REVIEW';
  for (const line of source.split(/\r?\n/)) {
    const t = line.match(/__tablename__\s*=\s*["']([^"']+)/); if (t) table = t[1];
    const c = line.match(/^\s+(\w+)(?:\s*:\s*Mapped\[.*?\])?\s*=\s*(?:Column|mapped_column)\((.*)/);
    if (!c) continue;
    const personal = /name|email|phone|cpf|cnpj|pix|token|secret|password|hash|avatar|image|content|body|message|text|payload|customer|chat|device|session|oauth|address|ip_|user_agent|document|prompt|response|url/i.test(c[1]);
    columns.push({ source: relative(root, file), sourceSha256: hash(source), table, column: c[1], classification: personal ? 'sensitive-or-free-text' : 'review-required', sanitizer: 'NOT_IMPLEMENTED', reviewed: false });
  }
}
writeFileSync(join(out, 'sanitization-inventory.json'), JSON.stringify({ method: 'Static candidate extraction, not complete SQL schema proof. Multiline/dynamic mappings require database catalog reconciliation.', gate: 'BLOCKED until every column reviewed and sanitization proven on synthetic PostgreSQL16 data, plus A/B realms when implemented', columns }, null, 2));
console.log(JSON.stringify({ configurationNames: envs.length, columnCandidates: columns.length, secretValuesRead: false }));

// Check candidate action names against the live AWS service authorization data.
// This is syntax/action evidence, not proof of effective AWS authorization.
import { devInfraPolicies } from './dev-infra-permissions.mjs';
import { readFileSync } from 'node:fs';

const inventory = JSON.parse(readFileSync(process.argv[2], 'utf8'));
const policies = devInfraPolicies(inventory);
const documents = [policies.plan, policies.apply, policies.runtimeBoundary, policies.flowBoundary];
const actions = [...new Set(documents.flatMap(d => d.Statement.flatMap(s => s.Action)))];
const serviceNames = { cloudwatch: 'cloudwatch' };
const serviceData = new Map();
for (const prefix of new Set(actions.map(action => action.split(':')[0]))) {
  const service = serviceNames[prefix] ?? prefix;
  const response = await fetch(`https://servicereference.us-east-1.amazonaws.com/v1/${service}/${service}.json`);
  if (!response.ok) throw new Error(`AWS reference unavailable for ${service}: ${response.status}`);
  const data = await response.json();
  serviceData.set(prefix, new Set(data.Actions.map(a => a.Name)));
}
const invalid = actions.filter(action => {
  const [prefix, name] = action.split(':');
  return !serviceData.get(prefix).has(name);
});
if (invalid.length) throw new Error(`Unknown IAM actions: ${invalid.join(', ')}`);
console.log(`${actions.length} exact IAM action names verified against the AWS service reference; live permissions remain unproven.`);

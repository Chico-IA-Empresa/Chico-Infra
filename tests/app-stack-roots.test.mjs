import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';

// UAT e Prod chamam modules/app-stack com a mesma superfície: o que for provado
// em UAT vale para Prod sem reescrita. Os dois arquivos abaixo têm de ser
// idênticos; o ambiente entra só por local.app_env no main.tf de cada root.
const read = (path) => readFileSync(path, 'utf8');
for (const file of ['app-stack.tf', 'app-stack-variables.tf']) {
  test(`${file} é idêntico em envs/uat e envs/prod`, () => {
    assert.equal(read(`envs/prod/${file}`), read(`envs/uat/${file}`));
  });
}
test('cada root declara o próprio ambiente e nada mais muda o env da pilha', () => {
  for (const env of ['uat', 'prod']) {
    assert.match(read(`envs/${env}/main.tf`), new RegExp(`app_env = "${env}"`));
  }
  assert.doesNotMatch(read('envs/uat/app-stack.tf'), /"(uat|prod)"/);
});
test('a composição saiu dos roots: nenhum bloco de aplicação ficou duplicado', () => {
  for (const env of ['uat', 'prod']) {
    for (const file of ['foundation', 'api', 'edge', 'migrate', 'workers', 'secrets', 'run-switches']) {
      assert.equal(existsSync(`envs/${env}/${file}.tf`), false, `envs/${env}/${file}.tf`);
    }
  }
});

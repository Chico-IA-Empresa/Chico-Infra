import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const source = readFileSync(new URL('../modules/dev-box/main.tf', import.meta.url), 'utf8');
const instance = source.split('resource "aws_instance" "this" {')[1].split('resource "aws_eip" "this" {')[0];
test('only the EIP-derived public-IP presence flag is ignored; initial launch stays false', () => {
  assert.match(instance, /associate_public_ip_address\s*=\s*false/);
  const ignored = [...instance.matchAll(/ignore_changes\s*=\s*\[([^\]]*)\]/g)];
  assert.equal(ignored.length, 1);
  assert.equal(ignored[0][1].trim(), 'associate_public_ip_address');
  assert.doesNotMatch(instance, /ignore_changes\s*=\s*all/);
});
test('instance, root and EIP protections remain explicit and user-data remains managed', () => {
  assert.match(instance, /prevent_destroy\s*=\s*true/);
  assert.match(instance, /user_data_replace_on_change\s*=\s*false/);
  assert.match(instance, /user_data\s*=\s*coalesce\(var\.bootstrap_user_data, local\.bootstrap\)/);
  assert.match(instance, /ami\s*=\s*var\.ami_id/);
  assert.match(instance, /encrypted\s*=\s*true/);
  assert.match(instance, /delete_on_termination\s*=\s*false/);
  assert.match(instance, /volume_size\s*=\s*var\.root_volume_size_gib/);
  const eip = source.split('resource "aws_eip" "this" {')[1];
  assert.match(eip, /instance\s*=\s*aws_instance\.this\.id/);
  assert.match(eip, /lifecycle\s*\{\s*prevent_destroy\s*=\s*true\s*\}/);
});

# Physical backup conversion staging

The Terraform root in `terraform/` combines the temporary version-bound access component and a separate x86 conversion host. Its backend is a distinct key under Dev, `dev/restore-staging.tfstate`, in the existing protected state bucket. Permanent Dev CI has no state access or administration over this root. Persistent resources remain in IaC. Provisioning defaults off; no existing Dev/shared root enables it.

Before planning an enabled root, reconcile ownership of all proposed IAM names and the SG, verify the current AMI/VPC/subnet, validate source selection and exact key/VersionId policy documents, confirm the existing Dev destination/host, current credit coverage, 160 GiB / max48h approval and peak quota. An ARM builder must not run concurrently. Bind all private inputs, source manifest, code, backend, lockfile, fixed lease and full saved plan to the review. Approval of capacity alone is not approval of an arbitrary plan. `restore_preflight` is review metadata, not a substitute for these proofs; do not populate it merely to make Terraform pass.

No source data, passphrase, payload secret or business row belongs in Terraform or public logs. A reviewed private cipher transfer and a pinned pgBackRest/PostgreSQL toolchain are prerequisites. Bootstrap only installs OS tools and sets a persistent absolute stop timer. It does not start PostgreSQL, export data, fetch a cipher or copy the source. Host, disk and SG use the temporary `env=restore` tag, outside CI's env=dev write scope; record temporary costs against the account-wide gross budget and approved envelope until cost attribution is explicitly reconciled.

The copied repository must be read-only. Use the fixed pgBackRest set, validate file checksums and required WAL before physical recovery, and capture tool output privately. Version2.57.0's verify implementation returns rendered status without throwing for every verification result, and includes a TODO for final required-WAL reconciliation: exit0 alone does not establish valid backup data. Require a successful detailed report and an independent WAL coverage check. Never run stanza-create, expire, repair or write against the legacy repository.

Use empty PGDATA and a network-isolated compatible container, disable preloads/replication/schedulers and business writers, inspect sensitive-data/schema/extension/collation requirements, then build the same-snapshot manifest and reviewed logical export. Own Dev credentials and targeted data treatment precede import into the empty Dev database. Measure the logical target and backup/proof workspace before import; the existing Dev disk limit must not be enlarged or data deleted silently.

Fixed lease expiry denies S3 independently and stops compute while preserving data on the stopped host. Storage charges continue. After the real Dev restore, own backup and independent recovery are proven, prepare a cleanup plan listing the instance and root volume ID, profile, policies and owned temporary artifacts. A reviewed termination deletes this temporary root volume; it must not occur before those gates. Expiry never auto-terminates, deletes backups, changes the source bucket or destroys permanent Dev resources. Preserve private evidence and the protected state.

This root is preparation only. Actual access/negative tests, current lease, timer/reboot behavior, egress isolation, payload/WAL integrity, compatibility, data reconciliation and cleanup remain runtime evidence requirements.

The dedicated [security gate](../../docs/restore-staging-security-review.md) scans this root with an explicitly synthetic, expired scanner fixture. Only two source-bound, dated exceptions are accepted; it never grants permission to provision or substitutes runtime verification.

## Version-pinned transfer

`copy-selected-source.py` is an operational transport for the approved Linux staging host, not a provisioning or database-restore script. AWS Core must first verify the actual instance/profile, encrypted volume, available capacity and lease against the reviewed plan. Deliver the exact frozen private source manifest and script by the reviewed private executor; do not regenerate a latest selection. Run only after the staging and source-access gates have passed:

```bash
python3 /opt/chico-restore/copy-selected-source.py \
  --manifest /run/chico-restore/source-selection.json \
  --manifest-sha256 "$REVIEWED_SOURCE_SHA256" \
  --destination "/srv/chico-restore/$IMPORT_ID" \
  --not-before "$REVIEWED_LEASE_START" --expires-at "$REVIEWED_LEASE_END"
```

The transport refuses root/permanent Dev/foreign AWS identities and requires `chico-dev-restore`. Its only AWS APIs are STS identity and versioned S3 GetObject; it never lists latest, writes the source, restores archived objects or syncs a repository. It validates manifest hash, safe unique paths, selected versions, returned sizes/ETag/timestamps, local bytes and SHA256. ETag is compared only as metadata; it is never assumed to be SHA256. A returned FULL_OBJECT SHA256 is checked when present; absent/composite checksums remain explicitly unverified.

It requires a fresh private directory and copy workspace; failures preserve partial files with a failure record and no completion marker. No automatic cleanup, resume, disk expansion or data deletion occurs. A successful transfer freezes local hashes and read-only permissions, then writes a private completion record. It explicitly leaves backup/WAL integrity and database restore unproven. Bind only the `repo/` child read-only into the isolated pinned toolchain; the private parent stays0700 and cipher configuration is a separate protected tmpfs mount. File permissions alone are not an immutable mount.

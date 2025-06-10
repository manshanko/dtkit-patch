dtkit-patch
===========

Simple tool for patching Darktide to setup [Darktide Mod Loader (DML)](https://github.com/Darktide-Mod-Framework/Darktide-Mod-Loader/).

dtkit-patch is based on Aussiemon's original nodejs script.

## About

dtkit-patch patches `bundle_database.data` to load `9ba626afa44a3aa3.patch_999` from DML.

When Darktide updates or validates files the `bundle_database.data` patch is removed.
Make sure to run dtkit-patch again to enable mods when that happens.

## Artifact Attestation

Since `0.1.8` release binaries do [artifact attestation](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations/using-artifact-attestations-to-establish-provenance-for-builds).

See [`manshanko/dtkit-patch/attestations`](https://github.com/manshanko/dtkit-patch/attestations).

[GitHub CLI](https://cli.github.com/) can verify files (requires GitHub account):
```
gh attestation verify dtkit-patch.exe --repo manshanko/dtkit-patch
```

Updater flow fixtures, signed with a throwaway **test** Ed25519 key in
minisign's "ED" (BLAKE2b-prehashed) format. The secret key was never saved;
`flow.pub` is only for tests. `spot-9.9.9+99.apk` is a text payload whose
SHA-256 is listed in the signed `SHA256SUMS`.

`../minisign/` holds fixtures made with the real `minisign` 0.12 (copied from
zwriter's tests/data/minisign) to prove the verifier reads minisign's output.

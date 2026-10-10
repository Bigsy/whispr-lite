#!/bin/bash
# Used only on disposable GitHub-hosted release runners. Never print secret values.
set -euo pipefail
task_keychain="$RUNNER_TEMP/whispr-signing.keychain-db"
task_certificate="$RUNNER_TEMP/whispr-certificate.p12"
task_notary_key="$RUNNER_TEMP/whispr-notary.p8"
if [[ "${1:-}" == cleanup ]]; then
  if [[ -f "$task_keychain" ]]; then security delete-keychain "$task_keychain"; fi
  rm -f "$task_certificate" "$task_notary_key"
  exit 0
fi
for name in DEVELOPER_ID_P12_BASE64 DEVELOPER_ID_P12_PASSWORD ASC_PRIVATE_KEY ASC_KEY_ID ASC_ISSUER_ID; do
  [[ -n "${!name:-}" ]] || { echo "Missing release secret: $name" >&2; exit 1; }
done
umask 077
printf '%s' "$DEVELOPER_ID_P12_BASE64" | base64 --decode > "$task_certificate"
printf '%s' "$ASC_PRIVATE_KEY" > "$task_notary_key"
task_password=$(openssl rand -hex 32)
security create-keychain -p "$task_password" "$task_keychain"
security set-keychain-settings -lut 21600 "$task_keychain"
security unlock-keychain -p "$task_password" "$task_keychain"
security import "$task_certificate" -P "$DEVELOPER_ID_P12_PASSWORD" -k "$task_keychain" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$task_password" "$task_keychain" >/dev/null
task_identity=$(security find-identity -v -p codesigning "$task_keychain" | sed -n 's/.*) \([A-F0-9]*\) "Developer ID Application:.*"/\1/p' | head -1)
[[ "$task_identity" =~ ^[A-F0-9]{40}$ ]] || { echo 'Certificate must be Developer ID Application' >&2; exit 1; }
{
  printf 'SIGN_IDENTITY=%s\n' "$task_identity"
  printf 'SIGN_KEYCHAIN=%s\n' "$task_keychain"
  printf 'DISTRIBUTION_SIGNING=1\n'
  printf 'APPLE_NOTARY_KEY_FILE=%s\n' "$task_notary_key"
} >> "$GITHUB_ENV"
rm -f "$task_certificate"

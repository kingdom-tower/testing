#!/usr/bin/env bash
set -euo pipefail

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
pages_branch="e2e/replace-$PAGES-$GITHUB_RUN_ID"
chart_name="replace-$PAGES-$GITHUB_RUN_ID"
tag="$chart_name-0.1.0+build.1"
export CR_OWNER=kingdom-tower CR_GIT_REPO=testing CR_PAGES_BRANCH="$pages_branch"
export GNUPGHOME
GNUPGHOME=$(mktemp -d)
gpg --batch --passphrase '' --quick-generate-key 'Replacement e2e <e2e@example.invalid>' rsa2048 sign 1d
gpg --batch --export-secret-keys > /tmp/secret.gpg
gpg --batch --export > /tmp/public.gpg
git worktree add --orphan -b "$pages_branch" /tmp/replace-index
git -C /tmp/replace-index commit --allow-empty -m 'Initialize replacement index'
git -C /tmp/replace-index push origin "$pages_branch"
git worktree remove /tmp/replace-index
git fetch origin "$pages_branch"

mkdir -p charts/selected
write_chart() {
  printf 'apiVersion: v2\nname: %s\nversion: %s\ndescription: %s\n' "$chart_name" "$1" "$2" > charts/selected/Chart.yaml
}
package_chart() {
  rm -rf .cr-release-packages
  /tmp/cr package charts/selected "$@"
}
upload=()
index=()
if [[ "$PAGES" == true ]]; then
  upload+=(--packages-with-index --push)
  index+=(--packages-with-index)
fi

# Publish an older version to prove replacement preserves other index entries.
write_chart 0.0.9 older
package_chart
/tmp/cr upload "${upload[@]}" --pre-release
/tmp/cr index "${index[@]}" --push

write_chart '0.1.0+build.1' original
package_chart --sign --key e2e@example.invalid --keyring /tmp/secret.gpg --passphrase-file /dev/null
/tmp/cr upload "${upload[@]}" --pre-release
/tmp/cr index "${index[@]}" --push
printf 'keep unrelated asset\n' > /tmp/notes.txt
gh release upload "$tag" /tmp/notes.txt
gh release edit "$tag" --notes 'Keep these release notes' --title 'Keep this title'

snapshot() {
  gh api "repos/$GITHUB_REPOSITORY/releases/tags/$tag" --jq '{id,tag_name,name,body,prerelease,target_commitish}' > "$1"
}
asset_id() {
  gh release view "$tag" --json assets --jq '.assets[] | select(.name == "notes.txt") | .id'
}
snapshot /tmp/release-before.json
asset_id > /tmp/notes-id-before
original_digest=$(sha256sum ".cr-release-packages/$tag.tgz" | cut -d ' ' -f 1)

verify() {
  local signed="$1"
  local expected_digest
  expected_digest=$(sha256sum ".cr-release-packages/$tag.tgz" | cut -d ' ' -f 1)
  test "$expected_digest" != "$original_digest"
  rm -rf /tmp/downloads
  mkdir /tmp/downloads
  gh release download "$tag" --dir /tmp/downloads
  cmp ".cr-release-packages/$tag.tgz" "/tmp/downloads/$tag.tgz"
  test "$(cat /tmp/downloads/notes.txt)" = 'keep unrelated asset'
  if [[ "$signed" == true ]]; then
    cmp ".cr-release-packages/$tag.tgz.prov" "/tmp/downloads/$tag.tgz.prov"
    gpg --verify "/tmp/downloads/$tag.tgz.prov"
    grep -F "$expected_digest" "/tmp/downloads/$tag.tgz.prov"
  else
    test ! -e "/tmp/downloads/$tag.tgz.prov"
  fi
  snapshot /tmp/release-after.json
  diff -u /tmp/release-before.json /tmp/release-after.json
  asset_id > /tmp/notes-id-after
  diff -u /tmp/notes-id-before /tmp/notes-id-after
  test "$(find /tmp/downloads -type f | wc -l)" = "$([[ "$signed" == true ]] && echo 3 || echo 2)"
  git fetch origin "$pages_branch"
  git show "origin/$pages_branch:index.yaml" > /tmp/index.yaml
  grep -F "digest: $expected_digest" /tmp/index.yaml
  grep -F 'version: 0.0.9' /tmp/index.yaml
  test "$(grep -c 'version: 0.1.0+build.1' /tmp/index.yaml)" = 1
  if [[ "$PAGES" == true ]]; then
    git show "origin/$pages_branch:$tag.tgz" > /tmp/pages.tgz
    cmp ".cr-release-packages/$tag.tgz" /tmp/pages.tgz
    if [[ "$signed" == true ]]; then
      git show "origin/$pages_branch:$tag.tgz.prov" > /tmp/pages.prov
      cmp ".cr-release-packages/$tag.tgz.prov" /tmp/pages.prov
    else
      if git cat-file -e "origin/$pages_branch:$tag.tgz.prov"; then
        echo 'Stale Pages provenance remains' >&2
        exit 1
      fi
    fi
  fi
}

# Replace with another signed package, then intentionally replace with unsigned.
write_chart '0.1.0+build.1' replacement-signed
package_chart --sign --key e2e@example.invalid --keyring /tmp/secret.gpg --passphrase-file /dev/null
/tmp/cr upload "${upload[@]}" --replace-existing
/tmp/cr index "${index[@]}" --replace-existing --push
verify true
write_chart '0.1.0+build.1' replacement-unsigned
package_chart
/tmp/cr upload "${upload[@]}" --replace-existing
/tmp/cr index "${index[@]}" --replace-existing --push
verify false

# Exact same bytes are idempotent, including Pages Git commits.
git fetch origin "$pages_branch"
before=$(git rev-parse "origin/$pages_branch")
/tmp/cr upload "${upload[@]}" --replace-existing
/tmp/cr index "${index[@]}" --replace-existing --push
git fetch origin "$pages_branch"
test "$before" = "$(git rev-parse "origin/$pages_branch")"
verify false

# Replacement opt-in must also create a missing release.
write_chart 0.2.0 new-release
package_chart
/tmp/cr upload "${upload[@]}" --replace-existing --pre-release
/tmp/cr index "${index[@]}" --replace-existing --push
gh release view "$chart_name-0.2.0"
echo 'PASS: replacement assets, provenance, metadata, checksums, older versions and reruns'

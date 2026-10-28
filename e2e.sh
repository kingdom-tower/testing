#!/usr/bin/env bash
set -Eeuo pipefail
trap 'printf "E2e failure at line %s\n" "$LINENO" >&2' ERR

chart_dirs=(app-0helper app different-directory indented numeric quoted)
versions=(2.0.0 1.0.0 3.0.0 1.2.3 1 1.2.3)

write_chart() {
  local directory="$1" name="$2" version="$3" style="$4"
  mkdir -p "charts/$directory"
  case "$style" in
    indented)
      printf '  apiVersion: v2\n  name: %s\n  version: %s\n' "$name" "$version"
      ;;
    quoted)
      printf 'apiVersion: v2\n"name": %s\n"version": %s\n' "$name" "$version"
      ;;
    *)
      printf 'apiVersion: v2\nname: %s\nversion: %s\n' "$name" "$version"
      ;;
  esac > "charts/$directory/Chart.yaml"
}

case "$1" in
  prepare)
    git config user.name 'github-actions[bot]'
    git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
    fixture_id="$CASE_ID-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
    name_prefix="output-$fixture_id"
    chart_names=("$name_prefix-app-0helper" "$name_prefix-app" "$name_prefix-actual-name" "$name_prefix-indented" "$name_prefix-numeric" "$name_prefix-quoted")
    baseline_prefix="e2e-output-baseline-$fixture_id"
    pages_branch="e2e/output-index-$fixture_id"
    source_branch="e2e/output-source-$fixture_id"
    printf '.cr-*\nchanged_charts.txt\nchart_version.txt\n' > .gitignore
    for i in "${!chart_dirs[@]}"; do
      write_chart "${chart_dirs[$i]}" "${chart_names[$i]}" 0.0.1 plain
    done
    write_chart untouched "$name_prefix-untouched" 0.0.1 plain
    git add .gitignore charts
    git commit -m 'Prepare previous chart versions'
    git tag "$baseline_prefix-initial"
    for i in "${!chart_dirs[@]}"; do
      version="${versions[$i]}"
      [[ "${chart_dirs[$i]}" != numeric ]] || version=1.0
      write_chart "${chart_dirs[$i]}" "${chart_names[$i]}" "$version" "${chart_dirs[$i]}"
    done
    git add charts
    git commit -m 'Update chart versions using varied valid YAML formats'
    git push origin "HEAD:refs/heads/$source_branch" "refs/tags/$baseline_prefix-initial"
    git worktree add --orphan -b "$pages_branch" /tmp/chart-output-index
    git -C /tmp/chart-output-index commit --allow-empty -m 'Initialize isolated e2e index'
    git -C /tmp/chart-output-index push origin "$pages_branch"
    git worktree remove /tmp/chart-output-index
    git fetch origin "$pages_branch"
    {
      echo "NAME_PREFIX=$name_prefix"
      echo "BASELINE_PREFIX=$baseline_prefix"
      echo "PAGES_BRANCH=$pages_branch"
      echo "SOURCE_BRANCH=$source_branch"
      printf 'EXPECTED_CHANGED=charts/%s' "${chart_dirs[0]}"
      printf ',charts/%s' "${chart_dirs[@]:1}"
      printf '\nEXPECTED_VERSIONS=%s-%s' "${chart_names[0]}" "${versions[0]}"
      for i in 1 2 3 4 5; do
        printf ',%s-%s' "${chart_names[$i]}" "${versions[$i]}"
      done
      printf '\n'
    } >> "$GITHUB_ENV"
    if [[ "$SIGNING" == true ]]; then
      key_dir="$RUNNER_TEMP/chart-output-signing"
      mkdir -m 700 "$key_dir"
      export GNUPGHOME="$key_dir"
      gpg --batch --passphrase '' --quick-generate-key 'Chart output e2e <e2e@example.invalid>' rsa2048 sign 1d
      gpg --batch --export-secret-keys > "$key_dir/secret.gpg"
      gpg --batch --export > "$key_dir/public.gpg"
      printf '\n' > "$key_dir/passphrase.txt"
      {
        echo 'CR_KEY=e2e@example.invalid'
        echo "CR_KEYRING=$key_dir/secret.gpg"
        echo "CR_PASSPHRASE_FILE=$key_dir/passphrase.txt"
        echo "PUBLIC_KEYRING=$key_dir/public.gpg"
      } >> "$GITHUB_ENV"
    fi
    ;;
  verify)
    : "${NAME_PREFIX:?}" "${PAGES_BRANCH:?}"
    printf 'changed_charts=%s\nchart_version=%s\n' "$ACTUAL_CHANGED" "$ACTUAL_VERSIONS"
    test "$ACTUAL_CHANGED" = "$EXPECTED_CHANGED"
    test "$ACTUAL_VERSIONS" = "$EXPECTED_VERSIONS"
    test ! -e .cr-package-tmp
    chart_names=("$NAME_PREFIX-app-0helper" "$NAME_PREFIX-app" "$NAME_PREFIX-actual-name" "$NAME_PREFIX-indented" "$NAME_PREFIX-numeric" "$NAME_PREFIX-quoted")
    git fetch origin "$PAGES_BRANCH"
    git show "origin/$PAGES_BRANCH:index.yaml" > /tmp/chart-output-index.yaml
    test "$(grep -c '^  [a-z]' /tmp/chart-output-index.yaml)" = 6
    for i in "${!chart_names[@]}"; do
      name="${chart_names[$i]}"
      tag="$name-${versions[$i]}"
      download_dir="/tmp/chart-output-downloads/$tag"
      mkdir -p "$download_dir"
      gh release download "$tag" --dir "$download_dir"
      cmp ".cr-release-packages/$tag.tgz" "$download_dir/$tag.tgz"
      identity=$(helm show chart "$download_dir/$tag.tgz" | awk '
        /^name:/ {name=$2}
        /^version:/ {version=$2; gsub(/["\047]/, "", version)}
        END {print name "-" version}
      ')
      test "$identity" = "$tag"
      digest=$(sha256sum "$download_dir/$tag.tgz" | cut -d ' ' -f 1)
      awk -v key="  $name:" '
        $0 == key {selected=1; next}
        selected && /^  [[:alnum:]_]/ {exit}
        selected {print}
      ' /tmp/chart-output-index.yaml > /tmp/chart-output-entry.yaml
      grep -Fx "    digest: $digest" /tmp/chart-output-entry.yaml
      grep -F "https://github.com/$GITHUB_REPOSITORY/releases/download/$tag/$tag.tgz" /tmp/chart-output-entry.yaml
      asset_count=$(gh release view "$tag" --json assets --jq '.assets | length')
      if [[ "$SIGNING" == true ]]; then
        test "$asset_count" = 2
        cmp ".cr-release-packages/$tag.tgz.prov" "$download_dir/$tag.tgz.prov"
        helm verify "$download_dir/$tag.tgz" --keyring "$PUBLIC_KEYRING"
      else
        test "$asset_count" = 1
        test ! -e "$download_dir/$tag.tgz.prov"
      fi
    done
    if gh release view "$NAME_PREFIX-untouched-0.0.1" > /tmp/untouched-release.log 2>&1; then
      echo 'Unchanged chart was unexpectedly released' >&2
      exit 1
    fi
    {
      echo "INDEX_COMMIT=$(git rev-parse "origin/$PAGES_BRANCH")"
      echo '### Merged PR #238 e2e'
      echo "- Runner: $RUNNER_OS / $RUNNER_ARCH"
      echo "- Signing: $SIGNING"
      echo '- Verified six current chart versions, matching release/index bytes and expected provenance.'
    } > /tmp/chart-output-summary
    head -1 /tmp/chart-output-summary >> "$GITHUB_ENV"
    tail -n +2 /tmp/chart-output-summary >> "$GITHUB_STEP_SUMMARY"
    ;;
  settle)
    : "${BASELINE_PREFIX:?}" "${SOURCE_BRANCH:?}" "${PAGES_BRANCH:?}"
    git tag "$BASELINE_PREFIX-settled"
    git commit --allow-empty -m 'No chart changes after publication'
    git push origin "HEAD:refs/heads/$SOURCE_BRANCH" "refs/tags/$BASELINE_PREFIX-settled"
    git fetch origin "$PAGES_BRANCH"
    ;;
  *)
    echo "Unknown e2e phase: $1" >&2
    exit 1
    ;;
esac

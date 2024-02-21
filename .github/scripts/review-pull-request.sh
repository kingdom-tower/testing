#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

repo=$1

get_prs() {
    gh search prs --repo="${repo}" --author=cpanato --state=open --json number --jq '.[].number'
}

readarray -t PRS < <(get_prs)
for pr in "${PRS[@]}"; do
  echo ">>> Reviewing PR: ${pr}"
#   gh pr review --approve --body="automated review" --repo=wolfi-dev/advisories "${pr}"

    # Approve PR
   curl \
    -o review_output.json \
    -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    https://api.github.com/repos/"${1}"/pulls/"${pr}"/reviews

done

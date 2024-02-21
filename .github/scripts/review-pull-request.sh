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
  gh pr review --approve --body="automated review" --repo=wolfi-dev/advisories "${pr}"
done

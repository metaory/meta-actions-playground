#!/bin/bash

# Logger
__log() {
  while [ "${1:-}" ]; do
    echo "${1}: ${!1}"
    shift
  done
}

# Test environment variables
__test() {
  while [ "${1:-}" ]; do
    if [ -z "${!1}" ]; then
      echo "missing $1"
      exit 1
    fi
    shift
  done
}
__test HOTFIX_PREFIX HOTFIX_MIN_APPROVALS FLIGHT_PREFIX FLIGHT_MIN_APPROVALS
__test TARGET_URL DESCRIPTION CONTEXT

# Pull Request Number from the event path
pr_num=$(jq --raw-output .pull_request.number "$GITHUB_EVENT_PATH")

# List reviews for a pull request
# https://docs.github.com/en/rest/pulls/reviews?apiVersion=2022-11-28#list-reviews-for-a-pull-request
raw=$(gh api \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  /repos/${{ github.repository }}/pulls/${pr_num}/reviews)

# Filter reviwers to APPROVED only
users=()
for row in $(echo "${raw}" | jq -r '.[] | @base64'); do
  _jq() {
    echo "${row}" | base64 --decode | jq -r "${1}"
  }
  state=$(_jq '.state')

  user=$(_jq '.user.login')

  case $state in
  'APPROVED')
    users+=("${user}")
    ;;
  'CHANGES_REQUESTED')
    # shellcheck disable=SC2206
    users=(${users[@]/${user}/})
    ;;
  *) ;;
  esac
done

# Deduplicate reviwers
declare -A uniq_tmp
for item in "${users[@]}"; do
  uniq_tmp[$item]=0
done

# Total Unique Approved Reviews
approved_count="${#uniq_tmp[@]}"

# Total Event Requested Reviewers Count
event_requested_reviewers_count=$(echo '${{ toJson(github.event.pull_request.requested_reviewers) }}' | jq '. | length')

# Total Requested Reviewers Count
requested_reviewers_count=$(gh api \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  /repos/respond-io/respond-io/pulls/4571/requested_reviewers | jq '.users | length')

# PR Source Branch
branch="${{ github.event.pull_request.head.ref }}"

# PR Base Branch
base="${{ github.event.pull_request.base.ref }}"

# Default Commit Status
state=failure

# Success Condition for Hotfix
if [[ $branch == ${HOTFIX_PREFIX}* && ${approved_count} -ge $HOTFIX_MIN_APPROVALS ]]; then
  state=success
fi

# Success Condition for Flight
if [[ $branch == ${FLIGHT_PREFIX}* && ${approved_count} -ge $FLIGHT_MIN_APPROVALS ]]; then
  state=success
fi

# Success Condition for anything Else
if [[ ${approved_count} -ge ${requested_reviewers_count} ]]; then
  state=success
fi

# ###### [ DEBUG ] ###### #
__log state branch base approved_count event_requested_reviewers_count requested_reviewers_count
echo "total count:" "${#users[@]}"
echo "unique approval:" "${!uniq_tmp[@]}"
# #########################

# Create Commit status
# https://docs.github.com/en/rest/commits/statuses?apiVersion=2022-11-28#create-a-commit-status
curl -L \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/repos/${{ github.repository }}/statuses/${{ github.event.pull_request.head.sha }} \
  -d "{\"state\":\"${state}\",\"target_url\":\"${TARGET_URL}\",\"description\":\"${DESCRIPTION}\",\"context\":\"${CONTEXT}\"}"

#!/bin/zsh

set -e

# Define tput commands for formatting
BOLD=$(tput bold)
RESET=$(tput sgr0)
TURQ=$(tput setaf 6)
GREY=$(tput setaf 8)

# Get team members from live-control-plane team
TEAM_MEMBERS=$(gh api graphql -f query='query {
    organization(login: "wbd-streaming") {
      team(slug: "live-control-plane") {
        members(first: 50) {
          edges {
            node {
              login
            }
          }
        }
      }
    }
  }' | jq -rc '
    .data.organization.team.members.edges |
    map(.node.login)
  ')

# Calculate date one month ago in ISO format
LAST_MONTH=$(date -v-1m -u +"%Y-%m-%dT%H:%M:%SZ")

RESULTS_JSON=$(gh api graphql \
  --paginate \
  -f query='query($endCursor: String) {
    repository(owner: "wbd-streaming", name: "live-orchestration") {
      pullRequests(
        first: 100
        after: $endCursor
        states: [OPEN, CLOSED, MERGED]
        orderBy: {field: UPDATED_AT, direction: DESC}
      ) {
        edges {
          node {
            author {
              login
            }
            number
            title
            url
            createdAt
            updatedAt
            reviews(
              states: [APPROVED]
              first: 50
            ) {
              edges {
                node {
                  author {
                    login
                  }
                  state
                  submittedAt
                }
              }
            }
          }
        }
      }
    }
  }' \
  | jq '.data.repository.pullRequests.edges' \
  | jq --arg lastMonth "$LAST_MONTH" \
    'map(
        select(.node.updatedAt >= $lastMonth)
    )')

# Parse results into nested JSON structure: reviewer -> author -> [PR nodes]
# Filter to only include team members as reviewers
REVIEWS=$(echo "$RESULTS_JSON" | jq --argjson teamMembers "$TEAM_MEMBERS" '
  reduce .[] as $pr ({}; 
    reduce $pr.node.reviews.edges[] as $review (.;
      if ($teamMembers | contains([$review.node.author.login])) then
        .[$review.node.author.login][$pr.node.author.login] += [$pr.node]
      else
        .
      end
    )
  )
')

REVIEW_SUMMARIES=$(echo "$REVIEWS" | jq -rc \
  --arg b "$BOLD" \
  --arg t "$TURQ" \
  --arg g "$GREY" \
  --arg r "$RESET" \
  '
    to_entries | 
    map({
      reviewer: .key, 
      total: [.value | to_entries[].value | length] | add,
      authors: .value
    }) | 
    sort_by(.total) | 
    reverse | 
    map({
      key: .reviewer,
      value: ($b + "@\(.reviewer)" + $r + ": \(.total) PRs approved" + "\n" + 
        (
          .authors | to_entries | map(
            "\n  " + $t + "\(.value | length) PRs by @\(.key)" + $r + "\n" + 
            (
              .value | to_entries | map(
                "\n    \(.key + 1). \(.value.title)\n" +
                $g + "       \(.value.url)" + $r
              ) | join("\n")
            )
          ) | join("\n")
        ))
    }) |
    from_entries
  ')

if [[ -o interactive ]]; then
    # Create a nicely formatted table with aligned review counts
  echo ""
  echo "${BOLD}=== Approval Summary (Last Month) ===${RESET}"
  echo ""

  # Get the longest reviewer name for alignment
  MAX_LENGTH=$(echo "$REVIEWS" | jq -r 'keys[] | length' | sort -n | tail -1)
  MAX_LENGTH=$(( MAX_LENGTH + 2 ))

  # Create the table header
  printf "${BOLD}%-${MAX_LENGTH}s${RESET} ${BOLD}%s${RESET}\n" "Reviewer" "Reviews"
  printf "%-${MAX_LENGTH}s %s\n" "$(printf '%*s' $MAX_LENGTH '' | tr ' ' '-')" "-------"

  # Print the data rows with proper alignment
  SUMMARY=$(echo "$REVIEWS" \
    | jq -r \
      --arg maxlen "$MAX_LENGTH" \
        '
        to_entries | 
        map({
          reviewer: .key, 
          total: [.value | to_entries[].value | length] | add
        }) | 
        sort_by(.total) | 
        reverse | 
        .[] | 
        "@\(.reviewer) \(.total)"
      ' \
      | xargs -L1 printf "%-${MAX_LENGTH}s ${TURQ}%7s${RESET}\n")
else
  echo "$REVIEWS" \
    | jq -r '
      [to_entries[]] |
      flatten | 
      map({
        reviewer: .key, 
        total: [.value | to_entries[].value | length] | add
      }) |
      sort_by(.total) | 
      reverse |
      to_entries |
      map({
        reviewer: .value.reviewer,
        total: .value.total
      }) |
      map("\(.reviewer) (\(.total) approvals)") |
      join("\n")
    ' | fzf \
      --border \
      --layout reverse \
      --preview-window=right:60% \
      --preview="jq -n -r --arg r {} --argjson s '$REVIEW_SUMMARIES' '\$s[(\$r | capture(\"(?<reviewer>[^ ]+)\").reviewer)]'" \
      --prompt="Select > " \
      --header="Top Approvers (Last 30d)"
fi

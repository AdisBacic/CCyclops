#!/bin/bash
# Injected-context helper: PR lists across GITHUB_SCOPE from config.sh (e.g.
# "org:acme" or "repo:acme/shop repo:acme/api" — GitHub ORs the terms), one
# per line as owner/repo#number title. One GraphQL search per call. Lives in a
# script because the slash command permission check rejects inline commands
# with $-expansions.
#
# Errors go to stdout on purpose: the commands' feed check must see them, so
# an expired token is a FEED FAILURE instead of a quiet "no PRs today".
#
# Usage: pr-feed.sh review-requested   open PRs awaiting my review
#        pr-feed.sh mine               my open PRs, with draft / review state
#        pr-feed.sh merged-week        my PRs merged in the last 7 days
# shellcheck source=/dev/null
. "$HOME/.claude/ccyclops/config.sh" || exit 1

line='"\(.repository.nameWithOwner)#\(.number) \(.title)"'
case "${1:-}" in
  review-requested) q="is:pr is:open review-requested:@me" ;;
  mine)             q="is:pr is:open author:@me"
                    line="$line"' + " [\(if .isDraft then "draft" else (.reviewDecision // "no review" | ascii_downcase) end)]"' ;;
  merged-week)      q="is:pr author:@me merged:>=$(date -v-7d '+%Y-%m-%d')" ;;
  *) echo "usage: $0 review-requested|mine|merged-week" >&2; exit 1 ;;
esac

if ! out=$(gh api graphql -f q="$q $GITHUB_SCOPE" --jq ".data.search.nodes[] | $line" -f query='
    query($q: String!) {
      search(query: $q, type: ISSUE, first: 100) {
        nodes { ... on PullRequest { number title isDraft reviewDecision repository { nameWithOwner } } }
      }
    }' 2>&1); then
  echo "error: GitHub search failed for \"$q $GITHUB_SCOPE\": $(printf '%s' "$out" | tr -s '\n' ' ' | cut -c1-300)"
  exit 1
fi
[ -z "$out" ] || printf '%s\n' "$out"

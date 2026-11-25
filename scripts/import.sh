# Print the TOML configuration of a live GitHub organization.
# Usage: octonix-import ORGANIZATION [REPOSITORY...]
organization=${1:?usage: octonix-import ORGANIZATION [REPOSITORY...]}
shift

# A listing that GitHub refuses, for example a ruleset on a free plan, counts as empty.
pages() {
  local output
  output=$(gh api --paginate --slurp "$1" 2>/dev/null) && echo "$output" || echo '[]'
}

# A missing object, for example the Pages site of a repository without one, counts as null.
object() {
  local output
  output=$(gh api "$1" 2>/dev/null) && echo "$output" || echo null
}

repository_json() {
  local slug="$organization/$1" rulesets='[]' id
  for id in $(pages "repos/$slug/rulesets?includes_parents=false&per_page=100" | jq --raw-output '.[][].id'); do
    rulesets=$(jq --compact-output --argjson ruleset "$(gh api "repos/$slug/rulesets/$id")" '. + [$ruleset]' <<<"$rulesets")
  done

  jq --null-input \
    --argjson repo "$(gh api "repos/$slug")" \
    --argjson labels "$(pages "repos/$slug/labels?per_page=100")" \
    --argjson variables "$(pages "repos/$slug/actions/variables?per_page=30")" \
    --argjson secrets "$(pages "repos/$slug/actions/secrets?per_page=100")" \
    --argjson keys "$(pages "repos/$slug/keys?per_page=100")" \
    --argjson hooks "$(pages "repos/$slug/hooks?per_page=100")" \
    --argjson environments "$(pages "repos/$slug/environments?per_page=100")" \
    --argjson collaborators "$(pages "repos/$slug/collaborators?affiliation=direct&per_page=100")" \
    --argjson teams "$(pages "repos/$slug/teams?per_page=100")" \
    --argjson autolinks "$(pages "repos/$slug/autolinks?per_page=100")" \
    --argjson pages "$(object "repos/$slug/pages")" \
    --argjson rulesets "$rulesets" \
    '
      # A listing page is an array, or an object that holds the array under a key.
      def items(key): [.[] | if type == "array" then .[] else .[key][]? end];
      def permission: {"read": "pull", "write": "push"}[.] // .;

      {
        description: ($repo.description // ""),
        visibility: $repo.visibility,
        hasIssues: $repo.has_issues,
        hasWiki: $repo.has_wiki,
        hasProjects: $repo.has_projects,
        defaultBranch: $repo.default_branch,
        deleteBranchOnMerge: $repo.delete_branch_on_merge,
        archived: $repo.archived,
        topics: $repo.topics,
        labels: ($labels | items("") | map({(.name): {color, description: (.description // "")}}) | add // {}),
        variables: ($variables | items("variables") | map({(.name): .value}) | add // {}),
        secrets: ($secrets | items("secrets") | map(.name)),
        deployKeys: ($keys | items("") | map({(.title): {key, readOnly: .read_only}}) | add // {}),
        webhooks: ($hooks | items("") | map({(.config.url): {
          events, active, contentType: (if .config.content_type == "form" then "form" else "json" end)
        }}) | add // {}),
        environments: ($environments | items("environments") | map({(.name): ({
          waitTimer: ([.protection_rules[]? | select(.type == "wait_timer") | .wait_timer] | first // 0)
        } + (if .deployment_branch_policy then {deploymentBranchPolicy: {
          protectedBranches: .deployment_branch_policy.protected_branches,
          customBranchPolicies: .deployment_branch_policy.custom_branch_policies
        }} else {} end))}) | add // {}),
        collaborators: ($collaborators | items("") | map({(.login): (.role_name | permission)}) | add // {}),
        teamAccess: ($teams | items("") | map({(.slug): (.permission | permission)}) | add // {}),
        autolinks: ($autolinks | items("") | map({(.key_prefix): {urlTemplate: .url_template, isAlphanumeric: .is_alphanumeric}}) | add // {}),
        pages: (if $pages then {branch: $pages.source.branch, path: $pages.source.path} else null end),
        rulesets: ($rulesets | map({(.name): ({
          target, enforcement, rules,
          bypassActors: [.bypass_actors[]? | {actorId: .actor_id, actorType: .actor_type, bypassMode: .bypass_mode}]
        } + (if .conditions.ref_name then {conditions: {refName: .conditions.ref_name}} else {} end))}) | add // {})
      }
      | del(..|nulls)
    '
}

team_json() {
  local team=$1
  jq --null-input \
    --argjson team "$(gh api "orgs/$organization/teams/$team")" \
    --argjson maintainers "$(pages "orgs/$organization/teams/$team/members?role=maintainer&per_page=100")" \
    --argjson members "$(pages "orgs/$organization/teams/$team/members?role=member&per_page=100")" \
    '
      def logins(role): map(.[] | {(.login): role}) | add // {};
      {description: ($team.description // ""), privacy: $team.privacy, members: ($maintainers | logins("maintainer")) + ($members | logins("member"))}
    '
}

if (($# > 0)); then
  repositories=("$@")
else
  mapfile -t repositories < <(pages "orgs/$organization/repos?type=all&per_page=100" | jq --raw-output '.[][].name')
fi
mapfile -t teams < <(pages "orgs/$organization/teams?per_page=100" | jq --raw-output '.[][].slug')

repositories_json='{}'
for repository in "${repositories[@]}"; do
  repositories_json=$(jq --compact-output --arg name "$repository" --argjson value "$(repository_json "$repository")" '. + {($name): $value}' <<<"$repositories_json")
done
teams_json='{}'
for team in "${teams[@]}"; do
  teams_json=$(jq --compact-output --arg name "$team" --argjson value "$(team_json "$team")" '. + {($name): $value}' <<<"$teams_json")
done

jq --null-input --arg organization "$organization" --argjson repositories "$repositories_json" --argjson teams "$teams_json" \
  '{organizations: {($organization): {repositories: $repositories, teams: $teams}}}' |
  json2toml

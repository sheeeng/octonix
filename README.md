# Octonix

Octonix manages GitHub resources declaratively with Nix. It does not use
Terraform. Each resource module emits GitHub API requests, and a generated
shell script sends them through the [GitHub command line interface][gh].

## Requirements

Install Nix with flakes enabled. Authenticate the GitHub command line
interface with `gh auth login`.

## Usage

Show the ordered requests without network access.

```bash
nix eval --json .#requests
```

Compare the requests with the live GitHub state, and show the pending
changes without a write.

```bash
nix run .#build
```

Show the same comparison, and send only the requests that change GitHub.

```bash
nix run .#switch
```

Each line starts with `+` for a create, `~` for a change, `-` for a
delete, or `=` for no change. A change shows each field with its live
value and its new value. The build applies the pending changes of earlier
requests before it compares later requests, so it shows the same changes
that the switch sends.

## Design

Nix evaluation stays pure and does not use the network. The switch script
reads the token at run time through `gh auth token`, so the token does not
enter the Nix store.

Each request has a name, a method, an endpoint, and a body. The `after` and
`before` options order the requests, and `lib.toposort` sorts them. An
unknown reference, a reference to the same request, or a cycle stops the
evaluation.

Octonix prefers idempotent `PATCH` and `PUT` requests. A request that must
run only one time sets `skipIfExists` to an endpoint. The switch script
skips the request when that endpoint exists and sends it when GitHub
returns HTTP 404. Any other failure stops the switch before it sends that
request. The switch checks each endpoint just before its request, so
earlier requests in the same switch can already have changed GitHub.

Each switch unarchives a repository before it applies settings, and
archives the repository again at the end when `archived` is true. A
request can set `onFailure`, and the switch script sends that cleanup
request when a later request fails. This archives the repository again
after a failed switch. Octonix
creates the default branch in an empty repository. It does not create or
rename branches in a repository that has commits.

## Resources

Declare organization settings in `organizations.<name>.settings` and the
immutable releases policy in `organizations.<name>.immutableReleases`.
Octonix sends only the settings that you declare, so other settings keep
their live values.

Declare repositories in `organizations.<name>.repositories.<name>`. Each
repository supports its settings, `topics`, `labels`, Actions `variables`,
Actions `secrets`, `deployKeys`, `rulesets`, `webhooks`, `environments`,
`collaborators`, `teamAccess`, `autolinks`, and `pages`. Declare teams in
`organizations.<name>.teams`, with their members. Octonix creates and
updates these resources. It deletes the ones that you omit only for the
kinds that `prune` lists.
GitHub sends an invitation to a collaborator who is not a member yet.
Octonix does not manage webhook secrets.

Declare each secret as a name in `secrets`. The switch script reads the
value from the environment variable with the same name, and it sets only a
secret that does not exist. GitHub never returns a secret value, so the
script cannot detect a changed value. The value never enters the Nix store.
GitHub cannot edit a deploy key, so delete a changed key by hand before the
next switch.

Set `prune` on a repository to delete undeclared items. It lists kinds:
`autolinks`, `collaborators`, `deployKeys`, `environments`, `labels`,
`rulesets`, `secrets`, `teamAccess`, `variables`, and `webhooks`. A build
prints each deletion with a minus sign, so you can review it before the
switch. Pruning `labels` deletes the default GitHub labels. Pruning
`environments` deletes the `github-pages` environment. Octonix never
prunes repositories, teams, team members, or organization settings.

```toml
prune = ["labels", "variables"]
```

## Use TOML Instead of Nix

Write the same options in a TOML file, and set `OCTONIX_CONFIG` to its
absolute path. The `--impure` option lets Nix read the variable.

```bash
export OCTONIX_CONFIG="$PWD/examples/stikkontakten.toml"
nix run --impure .#build
nix run --impure .#switch
```

Declare repository rulesets in
`organizations.<name>.repositories.<name>.rulesets.<name>`. The attribute
name is the ruleset name. GitHub gives each ruleset an identifier, so the
switch script finds the ruleset by its name. It updates the ruleset when it
exists and creates it when it does not. Write `rules` in the form that the GitHub REST API
accepts.

```nix
rulesets."Automatically Request Copilot Review" = {
  conditions.refName.include = [ "~ALL" ];
  rules = [
    {
      type = "copilot_code_review";
      parameters = {
        review_draft_pull_requests = true;
        review_on_push = true;
      };
    }
  ];
};
```

## Adopt an Existing Organization

Write the live state of an organization to a TOML file. The command reads
repository settings, topics, labels, variables, secret names, deploy keys,
webhooks, environments, collaborators, team access, autolinks, Pages,
rulesets, and teams with their members. Name repositories after the
organization to import only those repositories.

```bash
nix run .#import -- my-organization > octonix.toml
OCTONIX_CONFIG=$PWD/octonix.toml nix run --impure .#build
```

The build of an imported file shows no changes.

## Share Defaults

Set `repositoryDefaults` on an organization. Every repository of the
organization uses these options unless it sets the option itself.

```toml
[organizations.my-organization.repositoryDefaults]
hasWiki = false
deleteBranchOnMerge = true
```

## Validate in an Editor

Build a JSON Schema from the module options with `nix build .#schema`. An
editor with TOML schema support, such as Taplo, uses it to complete option
names and to reject a misspelled option.

## Run in Continuous Integration

Add `--check` to the build. It exits with status 3 when GitHub differs from
the configuration.

```bash
nix run .#build -- --check
```

The file `examples/workflows/octonix.yml` is a GitHub Actions workflow. It
shows the pending changes on a pull request, applies them after a merge to
the main branch, and fails a daily run when GitHub drifts.

## Layout

The `modules` directory holds the option declarations. The `lib` directory
exposes `evalConfig`, `mkSwitch`, `mkImport`, and `schema`. The `scripts`
directory holds the import script. The `examples` directory holds sample
configurations for the `stikkontakten` prototype organization.

[gh]: https://cli.github.com/

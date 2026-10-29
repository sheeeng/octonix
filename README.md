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
repository supports its settings, `topics`, `labels`, and Actions
`variables`. Octonix creates and updates labels and variables, and it does
not delete the ones that you omit.

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
exists and creates it when it does not. Octonix does not delete rulesets
that you do not declare. Write `rules` in the form that the GitHub REST API
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

## Layout

The `modules` directory holds the option declarations. The `lib` directory
exposes `evalConfig` and `mkSwitch`. The `examples` directory holds sample
configurations for the `stikkontakten` prototype organization.

[gh]: https://cli.github.com/

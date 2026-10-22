# Octonix

Octonix manages GitHub resources declaratively with Nix. It does not use
Terraform. Each resource module emits GitHub API requests, and a generated
shell script sends them through the [GitHub command line interface][gh].

## Requirements

Install Nix with flakes enabled. Authenticate the GitHub command line
interface with `gh auth login`.

## Usage

Show the ordered requests. This is the dry run.

```bash
nix eval --json .#requests
```

Send the requests to GitHub.

```bash
nix run .#switch
```

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

Declare repositories in `organizations.<name>.repositories.<name>`.

## Layout

The `modules` directory holds the option declarations. The `lib` directory
exposes `evalConfig` and `mkSwitch`. The `examples` directory holds sample
configurations for the `stikkontakten` prototype organization.

[gh]: https://cli.github.com/

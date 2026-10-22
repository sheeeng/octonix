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
unknown reference or a cycle stops the evaluation.

Octonix prefers idempotent `PATCH` and `PUT` requests. A `POST` request sets
`skipIfExists` to an endpoint, and the switch script skips the request when
that endpoint exists.

## Layout

The `modules` directory holds the option declarations. The `lib` directory
exposes `evalConfig` and `mkSwitch`. The `examples` directory holds sample
configurations for the `stikkontakten` prototype organization.

[gh]: https://cli.github.com/

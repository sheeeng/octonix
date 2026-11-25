# This submodule describes one repository ruleset and builds its request body.
{
  config,
  lib,
  name,
  ...
}:
let
  inherit (lib) mkOption types;
in
{
  options = {
    target = mkOption {
      type = types.enum [
        "branch"
        "push"
        "tag"
      ];
      default = "branch";
      description = "The kind of reference or event that the ruleset applies to.";
    };

    enforcement = mkOption {
      type = types.enum [
        "active"
        "disabled"
        "evaluate"
      ];
      default = "active";
      description = "The enforcement level of the ruleset. The `evaluate` level requires GitHub Enterprise.";
    };

    conditions.refName = {
      include = mkOption {
        type = types.listOf types.str;
        default = [ "~DEFAULT_BRANCH" ];
        description = "The reference patterns that the ruleset applies to. GitHub accepts `~ALL` and `~DEFAULT_BRANCH` as special patterns. A push ruleset ignores this option.";
      };

      exclude = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "The reference patterns that the ruleset does not apply to. A push ruleset ignores this option.";
      };
    };

    rules = mkOption {
      type = types.listOf (types.attrsOf types.anything);
      default = [ ];
      description = "The rules in the form that the GitHub REST API accepts, each with a `type` and optional `parameters`. Declare every parameter that GitHub returns, or the comparison shows a change on each switch.";
    };

    bypassActors = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            actorId = mkOption {
              type = types.nullOr types.int;
              default = null;
              description = "The identifier of the actor. A deploy key has no identifier.";
            };
            actorType = mkOption {
              type = types.enum [
                "DeployKey"
                "Integration"
                "OrganizationAdmin"
                "RepositoryRole"
                "Team"
              ];
              description = "The kind of actor that can bypass the ruleset.";
            };
            bypassMode = mkOption {
              type = types.enum [
                "always"
                "exempt"
                "pull_request"
              ];
              default = "always";
              description = "When the actor can bypass the ruleset.";
            };
          };
        }
      );
      default = [ ];
      description = "The actors that can bypass the ruleset. GitHub returns them only to repository administrators.";
    };

    body = mkOption {
      type = types.attrsOf types.anything;
      internal = true;
      readOnly = true;
      description = "The request body that creates or updates this ruleset.";
    };
  };

  config.body = {
    inherit name;
    inherit (config) target enforcement rules;
    bypass_actors = map (actor: {
      actor_id = actor.actorId;
      actor_type = actor.actorType;
      bypass_mode = actor.bypassMode;
    }) config.bypassActors;
  }
  // lib.optionalAttrs (config.target != "push") {
    conditions.ref_name = {
      inherit (config.conditions.refName) include exclude;
    };
  };
}

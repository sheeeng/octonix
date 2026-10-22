# This submodule describes one GitHub organization and collects the requests of its resources.
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
    repositories = mkOption {
      type = types.attrsOf (
        types.submoduleWith {
          modules = [ ./repository.nix ];
          specialArgs.organization = name;
        }
      );
      default = { };
      description = "The repositories that belong to this organization.";
    };

    requests = mkOption {
      type = types.attrsOf types.anything;
      internal = true;
      readOnly = true;
      description = "The requests that reconcile this organization.";
    };
  };

  config.requests = lib.mergeAttrsList (
    lib.mapAttrsToList (_: repository: repository.requests) config.repositories
  );
}

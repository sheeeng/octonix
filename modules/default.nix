# This module declares organizations and orders their GitHub API requests.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;

  entries = lib.attrValues config.requestGraph;
  runsBefore = first: second: lib.elem first.name second.after || lib.elem second.name first.before;
  sorted = lib.toposort runsBefore entries;
  unknownReferences = lib.concatMap (
    entry:
    map (reference: "${entry.name} -> ${reference}") (
      lib.filter (reference: reference == entry.name || !config.requestGraph ? ${reference}) (
        entry.after ++ entry.before
      )
    )
  ) entries;
in
{
  options = {
    organizations = mkOption {
      type = types.attrsOf (types.submodule ./organization.nix);
      default = { };
      description = "The GitHub organizations that octonix manages.";
    };

    requestGraph = mkOption {
      type = types.attrsOf (types.submodule ./request.nix);
      default = { };
      description = "The GitHub API requests with their ordering constraints.";
    };

    requests = mkOption {
      type = types.listOf types.anything;
      readOnly = true;
      description = "The GitHub API requests in dependency order.";
    };
  };

  config = {
    requestGraph = lib.mkMerge (
      lib.mapAttrsToList (_: organization: organization.requests) config.organizations
    );

    requests =
      if unknownReferences != [ ] then
        throw "octonix: these requests reference unknown requests or themselves: ${lib.concatStringsSep ", " unknownReferences}"
      else if sorted ? cycle then
        throw "octonix: the request graph contains a cycle: ${
          lib.concatMapStringsSep " -> " (entry: entry.name) sorted.cycle
        }"
      else
        map (
          entry:
          lib.filterAttrs (_: value: value != null) {
            inherit (entry)
              name
              method
              endpoint
              body
              skipIfExists
              onFailure
              ;
          }
        ) sorted.result;
  };
}

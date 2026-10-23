# This submodule describes one GitHub API request and its position in the dependency graph.
{ name, lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options = {
    name = mkOption {
      type = types.str;
      default = name;
      readOnly = true;
      description = "The unique name that other requests reference in `after` and `before`.";
    };

    method = mkOption {
      type = types.enum [
        "DELETE"
        "PATCH"
        "POST"
        "PUT"
      ];
      description = "The HTTP method.";
    };

    endpoint = mkOption {
      type = types.str;
      description = "The GitHub API endpoint relative to the API root.";
    };

    body = mkOption {
      type = types.attrsOf types.anything;
      default = { };
      description = "The JSON request body.";
    };

    skipIfExists = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "The endpoint that the switch script reads first. A successful read skips this request, and an HTTP 404 response runs it. Any other failure stops the switch.";
    };

    creates = mkOption {
      type = types.attrsOf (types.attrsOf types.anything);
      default = { };
      description = "The endpoints that this request creates, with the fields that GitHub returns for each endpoint right after the creation. Build mode uses them to preview later requests.";
    };

    onFailure = mkOption {
      type = types.nullOr (
        types.submodule {
          options = {
            method = mkOption {
              type = types.enum [
                "DELETE"
                "PATCH"
                "POST"
                "PUT"
              ];
              description = "The HTTP method of the cleanup request.";
            };
            endpoint = mkOption {
              type = types.str;
              description = "The GitHub API endpoint of the cleanup request.";
            };
            body = mkOption {
              type = types.attrsOf types.anything;
              default = { };
              description = "The JSON body of the cleanup request.";
            };
          };
        }
      );
      default = null;
      description = "The request that the switch script sends when a later request fails. The script registers it only after this request succeeds.";
    };

    after = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "The requests that must run before this request.";
    };

    before = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "The requests that must run after this request.";
    };
  };
}

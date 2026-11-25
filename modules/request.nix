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

    liveFields = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            endpoint = mkOption {
              type = types.str;
              description = "The endpoint that returns the live value of the field.";
            };
            filter = mkOption {
              type = types.str;
              description = "The jq filter that extracts the live value from the response. The filter receives every page of the response as an array.";
            };
          };
        }
      );
      default = { };
      description = "The body fields whose live value the endpoint of this request does not return. The comparison reads each of them from another endpoint.";
    };

    environmentSecret = mkOption {
      type = types.nullOr (
        types.submodule {
          options = {
            repository = mkOption {
              type = types.str;
              description = "The repository that owns the secret, in the form `owner/name`.";
            };
            name = mkOption {
              type = types.str;
              description = "The secret name, which is also the name of the environment variable that holds the value.";
            };
          };
        }
      );
      default = null;
      description = "A secret that the switch script sets with `gh secret set`, which encrypts the value. The script reads the value from the environment variable and sets only a missing secret, because GitHub never returns a secret value. Set `skipIfExists` to the endpoint of the secret.";
    };

    prune = mkOption {
      type = types.nullOr (
        types.submodule {
          options = {
            endpoint = mkOption {
              type = types.str;
              description = "The endpoint that lists the existing items.";
            };
            filter = mkOption {
              type = types.str;
              description = "The jq filter that turns every page of the listing into an array of records with a `key` and an `id`.";
            };
            keep = mkOption {
              type = types.listOf types.str;
              description = "The keys of the declared items. The switch script deletes each item with another key.";
            };
          };
        }
      );
      default = null;
      description = "The deletion of undeclared items. The `endpoint` of this request is the delete endpoint, and `{id}` stands for the identifier of each item. The `method` must be `DELETE`.";
    };

    lookup = mkOption {
      type = types.nullOr (
        types.submodule {
          options = {
            endpoint = mkOption {
              type = types.str;
              description = "The endpoint that lists the existing resources.";
            };
            filter = mkOption {
              type = types.str;
              description = "The jq filter that returns the identifier of the resource, or null when the resource does not exist. The filter receives every page of the response as an array.";
            };
            createMethod = mkOption {
              type = types.enum [
                "POST"
                "PUT"
              ];
              default = "POST";
              description = "The HTTP method that creates the resource.";
            };
            createEndpoint = mkOption {
              type = types.str;
              description = "The endpoint that creates the resource.";
            };
          };
        }
      );
      default = null;
      description = "The search for a resource that GitHub identifies by a generated identifier. The switch script replaces `{id}` in `endpoint` with the identifier that it finds. When it finds no identifier, it sends the body to `createEndpoint` instead.";
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

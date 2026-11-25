# This submodule describes the managed settings of one GitHub repository and emits its requests.
{
  config,
  lib,
  name,
  organization,
  ...
}:
let
  inherit (lib) mkOption types;
  slug = "${organization}/${name}";
  branchEndpoint = "repos/${slug}/branches/${lib.escapeURL config.defaultBranch}";
  archive = {
    method = "PATCH";
    endpoint = "repos/${slug}";
    body.archived = true;
  };

  # A resource that GitHub creates and edits at the same endpoint: a POST that runs only when the endpoint is absent, then an idempotent PATCH.
  collectionRequests =
    kind: items: toBody:
    lib.concatMapAttrs (
      itemName: item:
      let
        body = toBody itemName item;
        itemEndpoint = "repos/${slug}/${kind}/${lib.escapeURL itemName}";
        itemSlug = "${slug}/${kind}/${itemName}";
      in
      {
        "${itemSlug}/create" = {
          method = "POST";
          endpoint = "repos/${slug}/${kind}";
          inherit body;
          skipIfExists = itemEndpoint;
          creates.${itemEndpoint} = body;
          after = [ "${slug}/unarchive" ];
        };
        "${itemSlug}/settings" = {
          method = "PATCH";
          endpoint = itemEndpoint;
          inherit body;
          after = [ "${itemSlug}/create" ];
        };
      }
    ) items;

  collections =
    collectionRequests "labels" config.labels (
      itemName: label: {
        name = itemName;
        inherit (label) color description;
      }
    )
    // collectionRequests "actions/variables" config.variables (
      itemName: value: {
        name = itemName;
        inherit value;
      }
    );

  # GitHub identifies a ruleset by a generated identifier, so each request finds the ruleset by its unique name.
  rulesetRequests = lib.mapAttrs' (
    rulesetName: ruleset:
    lib.nameValuePair "${slug}/rulesets/${rulesetName}" {
      method = "PUT";
      endpoint = "repos/${slug}/rulesets/{id}";
      inherit (ruleset) body;
      lookup = {
        endpoint = "repos/${slug}/rulesets?includes_parents=false&per_page=100";
        filter = "[.[][] | select(.name == ${builtins.toJSON rulesetName}) | .id] | first";
        createEndpoint = "repos/${slug}/rulesets";
      };
      # A ruleset can block the first commit, so the rulesets wait for the default branch.
      after = [ "${slug}/initialize" ];
    }
  ) config.rulesets;

  # GitHub identifies a deploy key by a generated identifier, so each request finds the key by its unique title. GitHub cannot edit a deploy key, so a changed key stops the switch.
  deployKeyRequests = lib.mapAttrs' (
    title: deployKey:
    lib.nameValuePair "${slug}/deploy-keys/${title}" {
      method = "PATCH";
      endpoint = "repos/${slug}/keys/{id}";
      body = {
        inherit title;
        inherit (deployKey) key;
        read_only = deployKey.readOnly;
      };
      lookup = {
        endpoint = "repos/${slug}/keys?per_page=100";
        filter = "[.[][] | select(.title == ${builtins.toJSON title}) | .id] | first";
        createEndpoint = "repos/${slug}/keys";
      };
      after = [ "${slug}/unarchive" ];
    }
  ) config.deployKeys;

  secretRequests = lib.listToAttrs (
    map (
      secretName:
      lib.nameValuePair "${slug}/secrets/${secretName}" {
        method = "PUT";
        endpoint = "repos/${slug}/actions/secrets/${secretName}";
        skipIfExists = "repos/${slug}/actions/secrets/${secretName}";
        environmentSecret = {
          repository = slug;
          name = secretName;
        };
        after = [ "${slug}/unarchive" ];
      }
    ) config.secrets
  );

  managed = collections // rulesetRequests // deployKeyRequests // secretRequests;
in
{
  options = {
    description = mkOption {
      type = types.str;
      default = "";
      description = "The repository description.";
    };

    visibility = mkOption {
      type = types.enum [
        "public"
        "private"
        "internal"
      ];
      default = "private";
      description = "The repository visibility.";
    };

    hasIssues = mkOption {
      type = types.bool;
      default = true;
      description = "Whether the repository enables issues.";
    };

    hasWiki = mkOption {
      type = types.bool;
      default = false;
      description = "Whether the repository enables the wiki.";
    };

    hasProjects = mkOption {
      type = types.bool;
      default = false;
      description = "Whether the repository enables projects.";
    };

    defaultBranch = mkOption {
      type = types.str;
      default = "main";
      description = "The default branch name. Octonix creates this branch in an empty repository. It does not create or rename branches in a repository that has commits.";
    };

    deleteBranchOnMerge = mkOption {
      type = types.bool;
      default = true;
      description = "Whether GitHub deletes head branches after a merge.";
    };

    archived = mkOption {
      type = types.bool;
      default = false;
      description = "Whether the repository is archived.";
    };

    topics = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "The repository topics.";
    };

    labels = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            color = mkOption {
              type = types.strMatching "[0-9a-fA-F]{6}";
              description = "The label color as six hexadecimal digits without a hash sign.";
            };
            description = mkOption {
              type = types.str;
              default = "";
              description = "The label description.";
            };
          };
        }
      );
      default = { };
      description = "The labels by name. Octonix creates and updates these labels. It does not delete other labels.";
    };

    variables = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "The Actions variables by name. Octonix creates and updates these variables. It does not delete other variables.";
    };

    deployKeys = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            key = mkOption {
              type = types.str;
              description = "The public key.";
            };
            readOnly = mkOption {
              type = types.bool;
              default = true;
              description = "Whether the key has read access only.";
            };
          };
        }
      );
      default = { };
      description = "The deploy keys, keyed by their unique titles. GitHub cannot edit a deploy key, so delete a changed key by hand before the next switch. Octonix does not delete deploy keys that you do not declare.";
    };

    secrets = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "The Actions secret names. The switch script reads each value from the environment variable of the same name, and sets only a secret that does not exist. It never stores a value in the Nix store.";
    };

    rulesets = mkOption {
      type = types.attrsOf (types.submodule ./ruleset.nix);
      default = { };
      description = "The repository rulesets, keyed by their unique names. Octonix does not delete rulesets that you do not declare.";
    };

    requests = mkOption {
      type = types.attrsOf types.anything;
      internal = true;
      readOnly = true;
      description = "The requests that reconcile this repository.";
    };
  };

  config.requests = {
    "${slug}/create" = {
      method = "POST";
      endpoint = "orgs/${organization}/repos";
      body = {
        inherit name;
        inherit (config) visibility;
        auto_init = false;
      };
      skipIfExists = "repos/${slug}";
      # These fields are the documented defaults of the create endpoint.
      creates = {
        "repos/${slug}" = {
          inherit name;
          inherit (config) visibility;
          archived = false;
          delete_branch_on_merge = false;
          description = null;
          has_issues = true;
          has_projects = true;
          has_wiki = true;
        };
        "repos/${slug}/topics".names = [ ];
      };
    };

    # GitHub rejects edits to an archived repository, so every switch unarchives first and archives again when a later request fails.
    "${slug}/unarchive" = {
      method = "PATCH";
      endpoint = "repos/${slug}";
      body.archived = false;
      onFailure = if config.archived then archive else null;
      after = [ "${slug}/create" ];
    };

    # The first commit of an empty repository creates the default branch. A repository with other branches returns HTTP 404 instead.
    "${slug}/initialize" = {
      method = "PUT";
      endpoint = "repos/${slug}/contents/README.md";
      body = {
        message = "Initialize the repository.";
        content = "";
        branch = config.defaultBranch;
      };
      skipIfExists = branchEndpoint;
      # GitHub keeps the default branch of the organization after the first commit, so only the branch itself is projected.
      creates.${branchEndpoint}.name = config.defaultBranch;
      after = [ "${slug}/unarchive" ];
    };

    "${slug}/settings" = {
      method = "PATCH";
      endpoint = "repos/${slug}";
      body = {
        inherit (config) description visibility;
        has_issues = config.hasIssues;
        has_wiki = config.hasWiki;
        has_projects = config.hasProjects;
        default_branch = config.defaultBranch;
        delete_branch_on_merge = config.deleteBranchOnMerge;
      };
      after = [ "${slug}/initialize" ];
    };

    "${slug}/topics" = {
      method = "PUT";
      endpoint = "repos/${slug}/topics";
      body.names = config.topics;
      after = [ "${slug}/settings" ];
    };
  }
  // managed
  // lib.optionalAttrs config.archived {
    "${slug}/archive" = archive // {
      after = [ "${slug}/topics" ] ++ lib.attrNames managed;
    };
  };
}

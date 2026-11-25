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
  permission = types.enum [
    "admin"
    "maintain"
    "pull"
    "push"
    "triage"
  ];
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

  # Each request waits for the unarchive request, because GitHub rejects edits to an archived repository.
  afterUnarchive = [ "${slug}/unarchive" ];

  # GitHub identifies a webhook by a generated identifier, so each request finds the webhook by its unique address.
  webhookRequests = lib.mapAttrs' (
    url: webhook:
    lib.nameValuePair "${slug}/webhooks/${url}" {
      method = "PATCH";
      endpoint = "repos/${slug}/hooks/{id}";
      body = {
        inherit (webhook) active events;
        config = {
          inherit url;
          content_type = webhook.contentType;
          insecure_ssl = "0";
        };
      };
      lookup = {
        endpoint = "repos/${slug}/hooks?per_page=100";
        filter = "[.[][] | select(.config.url == ${builtins.toJSON url}) | .id] | first";
        createEndpoint = "repos/${slug}/hooks";
      };
      after = afterUnarchive;
    }
  ) config.webhooks;

  environmentRequests = lib.mapAttrs' (
    environment: declaration:
    let
      endpoint = "repos/${slug}/environments/${lib.escapeURL environment}";
    in
    lib.nameValuePair "${slug}/environments/${environment}" {
      method = "PUT";
      inherit endpoint;
      body = {
        wait_timer = declaration.waitTimer;
        deployment_branch_policy =
          if declaration.deploymentBranchPolicy == null then
            null
          else
            {
              protected_branches = declaration.deploymentBranchPolicy.protectedBranches;
              custom_branch_policies = declaration.deploymentBranchPolicy.customBranchPolicies;
            };
      };
      # The environment endpoint returns the wait timer inside its protection rules.
      liveFields.wait_timer = {
        inherit endpoint;
        filter = "(.[0].protection_rules // []) | map(select(.type == \"wait_timer\") | .wait_timer) | (first // 0)";
      };
      after = afterUnarchive;
    }
  ) config.environments;

  # The permission endpoints answer without a body, so the comparison reads the permission from a list. The list names the read and write roles differently from the request.
  permissionFilter =
    select: "([.[][] | select(${select}) | .role_name // .permission] | first // \"\") | ({\"read\": \"pull\", \"write\": \"push\"}[.] // .)";

  collaboratorRequests = lib.mapAttrs' (
    user: permission:
    lib.nameValuePair "${slug}/collaborators/${user}" {
      method = "PUT";
      endpoint = "repos/${slug}/collaborators/${user}";
      body = { inherit permission; };
      liveFields.permission = {
        endpoint = "repos/${slug}/collaborators?affiliation=direct&per_page=100";
        filter = permissionFilter ".login == ${builtins.toJSON user}";
      };
      after = afterUnarchive;
    }
  ) config.collaborators;

  teamAccessRequests = lib.mapAttrs' (
    team: permission:
    lib.nameValuePair "${slug}/teams/${team}" {
      method = "PUT";
      endpoint = "orgs/${organization}/teams/${team}/repos/${slug}";
      body = { inherit permission; };
      liveFields.permission = {
        endpoint = "repos/${slug}/teams?per_page=100";
        filter = permissionFilter ".slug == ${builtins.toJSON team}";
      };
      after = afterUnarchive ++ [ "${organization}/teams/${team}/settings" ];
    }
  ) config.teamAccess;

  managed =
    collections
    // rulesetRequests
    // deployKeyRequests
    // secretRequests
    // webhookRequests
    // environmentRequests
    // collaboratorRequests
    // teamAccessRequests;
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

    webhooks = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            events = mkOption {
              type = types.listOf types.str;
              default = [ "push" ];
              description = "The events that trigger the webhook.";
            };
            active = mkOption {
              type = types.bool;
              default = true;
              description = "Whether GitHub delivers the events.";
            };
            contentType = mkOption {
              type = types.enum [
                "form"
                "json"
              ];
              default = "json";
              description = "The media type of the payload.";
            };
          };
        }
      );
      default = { };
      description = "The webhooks, keyed by their unique payload addresses. Octonix does not manage webhook secrets, and it does not delete webhooks that you do not declare.";
    };

    environments = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            waitTimer = mkOption {
              type = types.ints.between 0 43200;
              default = 0;
              description = "The minutes that a deployment waits before it proceeds.";
            };
            deploymentBranchPolicy = mkOption {
              type = types.nullOr (
                types.submodule {
                  options = {
                    protectedBranches = mkOption {
                      type = types.bool;
                      description = "Whether only protected branches can deploy.";
                    };
                    customBranchPolicies = mkOption {
                      type = types.bool;
                      description = "Whether only branches that match custom policies can deploy.";
                    };
                  };
                }
              );
              default = null;
              description = "The branches that can deploy to the environment. A null value lets every branch deploy.";
            };
          };
        }
      );
      default = { };
      description = "The deployment environments by name. Octonix does not delete environments that you do not declare.";
    };

    collaborators = mkOption {
      type = types.attrsOf permission;
      default = { };
      description = "The direct collaborators by GitHub user name, with their repository permission. GitHub sends an invitation to a user who is not a collaborator yet. Octonix does not remove collaborators that you do not declare.";
    };

    teamAccess = mkOption {
      type = types.attrsOf permission;
      default = { };
      description = "The organization teams by slug, with their repository permission. Declare the team in `teams` of the organization.";
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

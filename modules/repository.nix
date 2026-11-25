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

  # Each kind has one listing. The lookups, the permission reads, and the prune requests all read it. The `items` filter selects the records of every page, the `key` filter gives the declared name, and the `id` filter gives the part of the item endpoint.
  listings =
    lib.mapAttrs
      (
        _: listing:
        {
          items = ".[][]";
          id = ".id";
        }
        // listing
      )
      {
        autolinks = {
          list = "autolinks?per_page=100";
          key = ".key_prefix";
        };
        collaborators = {
          list = "collaborators?affiliation=direct&per_page=100";
          key = ".login";
          id = ".login";
        };
        deployKeys = {
          list = "keys?per_page=100";
          key = ".title";
        };
        environments = {
          list = "environments?per_page=100";
          items = ".[].environments[]";
          key = ".name";
          id = "(.name | @uri)";
        };
        labels = {
          list = "labels?per_page=100";
          key = ".name";
          id = "(.name | @uri)";
        };
        rulesets = {
          list = "rulesets?includes_parents=false&per_page=100";
          key = ".name";
        };
        secrets = {
          list = "actions/secrets?per_page=100";
          items = ".[].secrets[]";
          key = ".name";
          id = ".name";
        };
        teamAccess = {
          list = "teams?per_page=100";
          key = ".slug";
          id = ".slug";
        };
        variables = {
          list = "actions/variables?per_page=30";
          items = ".[].variables[]";
          key = ".name";
          id = ".name";
        };
        webhooks = {
          list = "hooks?per_page=100";
          key = ".config.url";
        };
      };

  listingPath = kind: "repos/${slug}/${lib.head (lib.splitString "?" listings.${kind}.list)}";

  lookupFor =
    kind: itemName:
    let
      listing = listings.${kind};
    in
    {
      endpoint = "repos/${slug}/${listing.list}";
      filter = "[${listing.items} | select(${listing.key} == ${builtins.toJSON itemName}) | ${listing.id}] | first";
      createEndpoint = listingPath kind;
    };

  # GitHub identifies a ruleset by a generated identifier, so each request finds the ruleset by its unique name.
  rulesetRequests = lib.mapAttrs' (
    rulesetName: ruleset:
    lib.nameValuePair "${slug}/rulesets/${rulesetName}" {
      method = "PUT";
      endpoint = "repos/${slug}/rulesets/{id}";
      inherit (ruleset) body;
      lookup = lookupFor "rulesets" rulesetName;
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
      lookup = lookupFor "deployKeys" title;
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
      lookup = lookupFor "webhooks" url;
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
  permissionRead =
    kind: itemName:
    let
      listing = listings.${kind};
    in
    {
      endpoint = "repos/${slug}/${listing.list}";
      filter = "([${listing.items} | select(${listing.key} == ${builtins.toJSON itemName}) | .role_name // .permission] | first // \"\") | ({\"read\": \"pull\", \"write\": \"push\"}[.] // .)";
    };

  collaboratorRequests = lib.mapAttrs' (
    user: permission:
    lib.nameValuePair "${slug}/collaborators/${user}" {
      method = "PUT";
      endpoint = "repos/${slug}/collaborators/${user}";
      body = { inherit permission; };
      liveFields.permission = permissionRead "collaborators" user;
      after = afterUnarchive;
    }
  ) config.collaborators;

  teamAccessRequests = lib.mapAttrs' (
    team: permission:
    lib.nameValuePair "${slug}/teams/${team}" {
      method = "PUT";
      endpoint = "orgs/${organization}/teams/${team}/repos/${slug}";
      body = { inherit permission; };
      liveFields.permission = permissionRead "teamAccess" team;
      after = afterUnarchive ++ [ "${organization}/teams/${team}/settings" ];
    }
  ) config.teamAccess;

  # GitHub identifies an autolink by a generated identifier, so each request finds the autolink by its unique prefix. GitHub cannot edit an autolink, so a changed autolink stops the switch.
  autolinkRequests = lib.mapAttrs' (
    keyPrefix: autolink:
    lib.nameValuePair "${slug}/autolinks/${keyPrefix}" {
      method = "PATCH";
      endpoint = "repos/${slug}/autolinks/{id}";
      body = {
        key_prefix = keyPrefix;
        url_template = autolink.urlTemplate;
        is_alphanumeric = autolink.isAlphanumeric;
      };
      lookup = lookupFor "autolinks" keyPrefix;
      after = afterUnarchive;
    }
  ) config.autolinks;

  # GitHub Pages needs the source branch, so the requests wait for the first commit.
  pagesRequests = lib.optionalAttrs (config.pages != null) (
    let
      body.source = {
        inherit (config.pages) branch path;
      };
    in
    {
      "${slug}/pages/create" = {
        method = "POST";
        endpoint = "repos/${slug}/pages";
        inherit body;
        skipIfExists = "repos/${slug}/pages";
        creates."repos/${slug}/pages" = body;
        after = [ "${slug}/initialize" ];
      };
      "${slug}/pages/settings" = {
        method = "PUT";
        endpoint = "repos/${slug}/pages";
        inherit body;
        after = [ "${slug}/pages/create" ];
      };
    }
  );

  # The keys of the declared items. Pruning deletes every live item with another key.
  declaredKeys = {
    autolinks = lib.attrNames config.autolinks;
    collaborators = lib.attrNames config.collaborators;
    deployKeys = lib.attrNames config.deployKeys;
    environments = lib.attrNames config.environments;
    labels = lib.attrNames config.labels;
    rulesets = lib.attrNames config.rulesets;
    secrets = config.secrets;
    teamAccess = lib.attrNames config.teamAccess;
    variables = lib.attrNames config.variables;
    webhooks = lib.attrNames config.webhooks;
  };

  pruneRequests = lib.listToAttrs (
    map (
      kind:
      let
        listing = listings.${kind};
      in
      lib.nameValuePair "${slug}/prune/${kind}" {
        method = "DELETE";
        endpoint =
          if kind == "teamAccess" then
            "orgs/${organization}/teams/{id}/repos/${slug}"
          else
            "${listingPath kind}/{id}";
        prune = {
          endpoint = "repos/${slug}/${listing.list}";
          filter = "[${listing.items} | {key: ${listing.key}, id: ${listing.id}}]";
          keep = declaredKeys.${kind};
        };
        after = afterUnarchive;
      }
    ) config.prune
  );

  managed =
    pagesRequests
    // autolinkRequests
    // collections
    // rulesetRequests
    // deployKeyRequests
    // secretRequests
    // webhookRequests
    // environmentRequests
    // collaboratorRequests
    // teamAccessRequests
    // pruneRequests;
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
      description = "The labels by name. Octonix creates and updates these labels. It deletes other labels only when `prune` lists labels.";
    };

    variables = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "The Actions variables by name. Octonix creates and updates these variables. It deletes other variables only when `prune` lists variables.";
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
      description = "The deploy keys, keyed by their unique titles. GitHub cannot edit a deploy key, so delete a changed key by hand before the next switch. Octonix deletes undeclared deploy keys only when `prune` lists them.";
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
      description = "The webhooks, keyed by their unique payload addresses. Octonix does not manage webhook secrets, and it deletes undeclared webhooks only when `prune` lists them.";
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
      description = "The deployment environments by name. Octonix deletes undeclared environments only when `prune` lists them.";
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

    autolinks = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            urlTemplate = mkOption {
              type = types.str;
              description = "The link target, which contains `<num>` for the reference number.";
            };
            isAlphanumeric = mkOption {
              type = types.bool;
              default = true;
              description = "Whether the reference accepts letters as well as digits.";
            };
          };
        }
      );
      default = { };
      description = "The autolinks, keyed by their unique reference prefixes. GitHub cannot edit an autolink, so delete a changed autolink by hand before the next switch. Octonix deletes undeclared autolinks only when `prune` lists them.";
    };

    pages = mkOption {
      type = types.nullOr (
        types.submodule {
          options = {
            branch = mkOption {
              type = types.str;
              default = "main";
              description = "The branch that GitHub publishes.";
            };
            path = mkOption {
              type = types.enum [
                "/"
                "/docs"
              ];
              default = "/";
              description = "The directory of the branch that GitHub publishes.";
            };
          };
        }
      );
      default = null;
      description = "The GitHub Pages site that publishes a branch. A null value leaves the site alone. A free organization can publish only public repositories.";
    };

    rulesets = mkOption {
      type = types.attrsOf (types.submodule ./ruleset.nix);
      default = { };
      description = "The repository rulesets, keyed by their unique names. Octonix deletes undeclared rulesets only when `prune` lists them.";
    };

    prune = mkOption {
      type = types.listOf (types.enum (lib.attrNames listings));
      default = [ ];
      description = "The kinds of resource where Octonix deletes every item that you do not declare. A build lists each deletion before the switch makes it. Pruning `labels` also deletes the default GitHub labels. Pruning `environments` also deletes the `github-pages` environment that GitHub Pages creates.";
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

# This submodule describes one GitHub organization and collects the requests of its resources.
{
  config,
  lib,
  name,
  ...
}:
let
  inherit (lib) mkOption types;

  toSnakeCase = lib.stringAsChars (
    character:
    let
      lower = lib.toLower character;
    in
    if character != lower then "_${lower}" else character
  );

  setting =
    type: description:
    mkOption {
      type = types.nullOr type;
      default = null;
      inherit description;
    };

  settingsBody = lib.filterAttrs (_: value: value != null) (
    lib.mapAttrs' (option: value: lib.nameValuePair (toSnakeCase option) value) config.settings
  );

  inherit (config.immutableReleases) enforcedRepositories selectedRepositoryIds;
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

    # Octonix sends only the settings that are not null, so undeclared settings keep their live values.
    settings = {
      billingEmail = setting types.str "The private billing email address.";
      blog = setting types.str "The blog address.";
      company = setting types.str "The company name.";
      defaultRepositoryPermission = setting (types.enum [
        "admin"
        "none"
        "read"
        "write"
      ]) "The default permission that members have for organization repositories.";
      deployKeysEnabledForRepositories = setting types.bool "Whether repositories can add and use deploy keys.";
      description = setting types.str "The organization description, up to 160 characters.";
      email = setting types.str "The public email address.";
      hasOrganizationProjects = setting types.bool "Whether the organization can use organization projects.";
      hasRepositoryProjects = setting types.bool "Whether organization repositories can use repository projects.";
      location = setting types.str "The location.";
      membersCanCreateInternalRepositories = setting types.bool "Whether members can create internal repositories. This requires GitHub Enterprise.";
      membersCanCreatePages = setting types.bool "Whether members can create GitHub Pages sites.";
      membersCanCreatePrivatePages = setting types.bool "Whether members can create private GitHub Pages sites.";
      membersCanCreatePrivateRepositories = setting types.bool "Whether members can create private repositories.";
      membersCanCreatePublicPages = setting types.bool "Whether members can create public GitHub Pages sites.";
      membersCanCreatePublicRepositories = setting types.bool "Whether members can create public repositories.";
      membersCanCreateRepositories = setting types.bool "Whether members who are not administrators can create repositories.";
      membersCanForkPrivateRepositories = setting types.bool "Whether members can fork private organization repositories.";
      name = setting types.str "The display name of the organization.";
      secretScanningPushProtectionCustomLink = setting types.str "The address that GitHub shows to contributors whom push protection blocks.";
      twitterUsername = setting types.str "The Twitter username.";
      webCommitSignoffRequired = setting types.bool "Whether contributors must sign off on commits that they make in the web interface.";
    };

    immutableReleases = {
      enforcedRepositories = setting (types.enum [
        "all"
        "none"
        "selected"
      ]) "The repositories in which GitHub enforces immutable releases.";

      selectedRepositoryIds = mkOption {
        type = types.listOf types.ints.positive;
        default = [ ];
        description = "The identifiers of the repositories that enforce immutable releases when `enforcedRepositories` is `selected`.";
      };
    };

    requests = mkOption {
      type = types.attrsOf types.anything;
      internal = true;
      readOnly = true;
      description = "The requests that reconcile this organization.";
    };
  };

  config.requests =
    lib.mergeAttrsList (lib.mapAttrsToList (_: repository: repository.requests) config.repositories)
    // lib.optionalAttrs (settingsBody != { }) {
      "${name}/settings" = {
        method = "PATCH";
        endpoint = "orgs/${name}";
        body = settingsBody;
      };
    }
    // lib.optionalAttrs (enforcedRepositories != null) {
      "${name}/immutable-releases" = {
        method = "PUT";
        endpoint = "orgs/${name}/settings/immutable-releases";
        body =
          if enforcedRepositories == "selected" then
            {
              enforced_repositories = enforcedRepositories;
              selected_repository_ids = selectedRepositoryIds;
            }
          else if selectedRepositoryIds != [ ] then
            throw "octonix: ${name} sets immutableReleases.selectedRepositoryIds, which requires enforcedRepositories = \"selected\""
          else
            { enforced_repositories = enforcedRepositories; };
      };
    };
}

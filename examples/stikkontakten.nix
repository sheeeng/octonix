# This example declares the stikkontakten prototype organization with one repository for each visibility that it supports.
# A free organization cannot use the internal visibility, which requires GitHub Enterprise.
{ lib, ... }:
{
  organizations.stikkontakten = {
    settings = {
      defaultRepositoryPermission = "read";
      membersCanForkPrivateRepositories = false;
      name = "Stikkontakten";
      webCommitSignoffRequired = false;
    };

    immutableReleases.enforcedRepositories = "none";

    repositories = lib.listToAttrs (
      map
        (
          visibility:
          lib.nameValuePair "${visibility}-example" {
            inherit visibility;
            description = "Demonstrate how Octonix manages a ${visibility} GitHub repository.";
            topics = [
              "nix"
              "octonix"
            ];
          }
        )
        [
          "private"
          "public"
        ]
    );
  };
}

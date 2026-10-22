# This example declares one repository for each visibility that the stikkontakten prototype organization supports.
# A free organization cannot use the internal visibility, which requires GitHub Enterprise.
{ lib, ... }:
{
  organizations.stikkontakten.repositories = lib.listToAttrs (
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
}

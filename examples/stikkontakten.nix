# This example declares a sandbox repository in the stikkontakten prototype organization.
{
  organizations.stikkontakten.repositories = {
    octonix-sandbox = {
      description = "Sandbox repository that octonix manages.";
      topics = [
        "nix"
        "octonix"
      ];
    };
  };
}

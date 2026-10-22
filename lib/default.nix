# This library evaluates octonix modules and renders their requests into a switch script.
{ lib }:
{
  evalConfig =
    modules:
    (lib.evalModules {
      modules = [ ../modules ] ++ modules;
    }).config;

  mkSwitch =
    pkgs: requests:
    pkgs.writeShellApplication {
      name = "octonix-switch";
      runtimeInputs = [ pkgs.gh ];
      text = ''
        GH_TOKEN="$(gh auth token)"
        export GH_TOKEN

        send() {
          local name=$1 method=$2 endpoint=$3 body=$4 skip_if_exists=$5
          if [[ -n $skip_if_exists ]] && gh api --silent "$skip_if_exists" 2>/dev/null; then
            echo "skip $name"
            return
          fi
          echo "$method $endpoint ($name)"
          printf '%s' "$body" | gh api --method "$method" --input - --silent "$endpoint"
        }

      ''
      + lib.concatMapStringsSep "\n" (
        request:
        lib.escapeShellArgs [
          "send"
          request.name
          request.method
          request.endpoint
          (builtins.toJSON request.body)
          (request.skipIfExists or "")
        ]
      ) requests;
    };
}

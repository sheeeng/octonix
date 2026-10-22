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

        cleanups=()

        run_cleanups() {
          local status=$? index
          trap - EXIT
          if ((status != 0)); then
            for ((index = ''${#cleanups[@]} - 3; index >= 0; index -= 3)); do
              echo "cleanup ''${cleanups[index]} ''${cleanups[index + 1]}" >&2
              printf '%s' "''${cleanups[index + 2]}" |
                gh api --method "''${cleanups[index]}" --input - --silent "''${cleanups[index + 1]}" ||
                echo "octonix: the cleanup request to ''${cleanups[index + 1]} failed" >&2
            done
          fi
          exit "$status"
        }
        trap run_cleanups EXIT

        exists() {
          local response
          if response=$(gh api --include "$1" 2>&1); then
            return 0
          fi
          if [[ $response =~ ^HTTP/[0-9.]+\ 404\  ]]; then
            return 1
          fi
          printf 'octonix: cannot check %s\n%s\n' "$1" "$response" >&2
          exit 1
        }

        send() {
          local name=$1 method=$2 endpoint=$3 body=$4 skip_if_exists=$5
          local failure_method=$6 failure_endpoint=$7 failure_body=$8
          if [[ -n $skip_if_exists ]] && exists "$skip_if_exists"; then
            echo "skip $name"
            return
          fi
          echo "$method $endpoint ($name)"
          printf '%s' "$body" | gh api --method "$method" --input - --silent "$endpoint"
          if [[ -n $failure_method ]]; then
            cleanups+=("$failure_method" "$failure_endpoint" "$failure_body")
          fi
        }

      ''
      + lib.concatMapStringsSep "\n" (
        request:
        let
          onFailure = request.onFailure or null;
        in
        lib.escapeShellArgs [
          "send"
          request.name
          request.method
          request.endpoint
          (builtins.toJSON request.body)
          (request.skipIfExists or "")
          (if onFailure == null then "" else onFailure.method)
          (if onFailure == null then "" else onFailure.endpoint)
          (if onFailure == null then "" else builtins.toJSON onFailure.body)
        ]
      ) requests;
    };
}

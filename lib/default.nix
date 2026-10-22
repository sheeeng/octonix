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
      runtimeInputs = [
        pkgs.gh
        pkgs.jq
      ];
      text = ''
        mode=switch
        if [[ ''${1-} == --build ]]; then
          mode=build
        fi

        if [[ -t 1 ]]; then
          green=$'\e[32m' yellow=$'\e[33m' dim=$'\e[2m' reset=$'\e[0m'
        else
          green="" yellow="" dim="" reset=""
        fi

        GH_TOKEN="$(gh auth token)"
        export GH_TOKEN

        created=0 changed=0 unchanged=0
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

        # The fetch function stores the response body in live. It returns 1 for HTTP 404 and stops the switch on any other failure.
        fetch() {
          local response status_line
          response=$(gh api --include "$1" 2>&1) || true
          status_line=''${response%%$'\r'*}
          if [[ $status_line =~ ^HTTP/[0-9.]+\ 2 ]]; then
            live=''${response#*$'\r\n\r\n'}
            return 0
          fi
          if [[ $status_line =~ ^HTTP/[0-9.]+\ 404\  ]]; then
            live='{}'
            return 1
          fi
          printf 'octonix: cannot read %s\n%s\n' "$1" "$response" >&2
          exit 1
        }

        # The difference function prints each body field whose live value differs, and it ignores the order of arrays.
        difference() {
          jq --null-input --raw-output --argjson live "$live" --argjson desired "$1" '
            def normalize: if type == "array" then sort else . end;
            $desired
            | to_entries[]
            | select((.value | normalize) != ($live[.key] | normalize))
            | "    \(.key): \($live[.key] | tojson) -> \(.value | tojson)"
          '
        }

        reconcile() {
          local name=$1 method=$2 endpoint=$3 body=$4 skip_if_exists=$5
          local failure_method=$6 failure_endpoint=$7 failure_body=$8
          local changes=""

          if [[ -n $skip_if_exists ]]; then
            if fetch "$skip_if_exists"; then
              echo "''${dim}= $name''${reset}"
              unchanged=$((unchanged + 1))
              return
            fi
            echo "''${green}+ $name''${reset}"
            created=$((created + 1))
          elif [[ $method == POST ]]; then
            echo "''${green}+ $name''${reset}"
            created=$((created + 1))
          elif fetch "$endpoint"; then
            changes=$(difference "$body")
            if [[ -z $changes ]]; then
              echo "''${dim}= $name''${reset}"
              unchanged=$((unchanged + 1))
              return
            fi
            echo "''${yellow}~ $name''${reset}"
            echo "$changes"
            changed=$((changed + 1))
          else
            echo "''${green}+ $name''${reset}"
            difference "$body"
            created=$((created + 1))
          fi

          if [[ $mode == build ]]; then
            return
          fi
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
          "reconcile"
          request.name
          request.method
          request.endpoint
          (builtins.toJSON request.body)
          (request.skipIfExists or "")
          (if onFailure == null then "" else onFailure.method)
          (if onFailure == null then "" else onFailure.endpoint)
          (if onFailure == null then "" else builtins.toJSON onFailure.body)
        ]
      ) requests
      + ''

        if [[ $mode == build ]]; then
          echo "Build: $created to create, $changed to change, $unchanged unchanged."
        else
          echo "Switch: $created created, $changed changed, $unchanged unchanged."
        fi
      '';
    };
}

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
          green=$'\e[32m' yellow=$'\e[33m' red=$'\e[31m' dim=$'\e[2m' reset=$'\e[0m'
        else
          green="" yellow="" red="" dim="" reset=""
        fi

        GH_TOKEN="$(gh auth token)"
        export GH_TOKEN

        created=0 changed=0 deleted=0 unchanged=0
        cleanups=()
        declare -A projected=()

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

        # The project function applies the pending bodies of earlier requests to live, because build mode does not send them.
        project() {
          local pending=''${projected[$1]-}
          if [[ -n $pending ]]; then
            live=$(jq --null-input --compact-output --argjson live "$live" --argjson pending "$pending" '$live + $pending')
          fi
        }

        reconcile() {
          local name=$1 method=$2 endpoint=$3 body=$4 skip_if_exists=$5
          local failure_method=$6 failure_endpoint=$7 failure_body=$8
          local action changes="" pending

          if [[ -n $skip_if_exists ]]; then
            if fetch "$skip_if_exists"; then action=unchanged; else action=create; fi
          elif [[ $method == POST ]]; then
            action=create
          elif [[ $method == DELETE ]]; then
            if fetch "$endpoint"; then action=delete; else action=unchanged; fi
          elif fetch "$endpoint"; then
            project "$endpoint"
            changes=$(difference "$body")
            if [[ -z $changes ]]; then action=unchanged; else action=change; fi
          else
            project "$endpoint"
            changes=$(difference "$body")
            action=create
          fi

          case $action in
            create)
              echo "''${green}+ $name''${reset}"
              created=$((created + 1))
              ;;
            change)
              echo "''${yellow}~ $name''${reset}"
              changed=$((changed + 1))
              ;;
            delete)
              echo "''${red}- $name''${reset}"
              deleted=$((deleted + 1))
              ;;
            unchanged)
              echo "''${dim}= $name''${reset}"
              unchanged=$((unchanged + 1))
              ;;
          esac
          if [[ -n $changes ]]; then
            echo "$changes"
          fi

          if [[ $mode == build ]]; then
            if [[ $action != unchanged && ($method == PATCH || $method == PUT) ]]; then
              pending=''${projected[$endpoint]-}
              projected[$endpoint]=$(jq --null-input --compact-output --argjson pending "''${pending:-null}" --argjson body "$body" '($pending // {}) + $body')
            fi
            return
          fi

          if [[ $action != unchanged ]]; then
            printf '%s' "$body" | gh api --method "$method" --input - --silent "$endpoint"
          fi
          # The cleanup also covers a request that was already satisfied, because a later failure can still leave the wrong state.
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
          echo "Build: $created to create, $changed to change, $deleted to delete, $unchanged unchanged."
        else
          echo "Switch: $created created, $changed changed, $deleted deleted, $unchanged unchanged."
        fi
      '';
    };
}

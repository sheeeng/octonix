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
        case "$*" in
          "") mode=switch ;;
          --build) mode=build ;;
          *)
            echo "usage: octonix-switch [--build]" >&2
            exit 2
            ;;
        esac

        if [[ -t 1 ]]; then
          green=$'\e[32m' yellow=$'\e[33m' red=$'\e[31m' dim=$'\e[2m' reset=$'\e[0m'
        else
          green="" yellow="" red="" dim="" reset=""
        fi

        GH_TOKEN="$(gh auth token)"
        export GH_TOKEN

        created=0 changed=0 deleted=0 unchanged=0
        cleanups=()
        declare -A projected=() presence=()

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

        # The fetch function stores the response body in live. It returns 1 for an absent status, HTTP 404 by default, and stops the switch on any other failure.
        fetch() {
          local response status_line absent=''${2:-404}
          response=$(gh api --include "$1" 2>&1) || true
          status_line=''${response%%$'\r'*}
          if [[ $status_line =~ ^HTTP/[0-9.]+\ 2 ]]; then
            # An HTTP 204 response has no body, and command substitution removes the final line break of its headers.
            live=""
            if [[ $response == *$'\r\n\r\n'* ]]; then
              live=''${response#*$'\r\n\r\n'}
            fi
            if [[ -z $live ]]; then
              live='{}'
            fi
            return 0
          fi
          if [[ $status_line =~ ^HTTP/[0-9.]+\ ($absent)\  ]]; then
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

        # Build mode does not send requests, so it records their effects. The presence array holds present or absent for each endpoint, and the projected array holds pending fields.
        remember() {
          local pending=''${projected[$1]-}
          projected[$1]=$(jq --null-input --compact-output --argjson pending "''${pending:-null}" --argjson body "$2" '($pending // {}) + $body')
        }

        # The observe function reads an endpoint like fetch, reads the live fields of the body, and then applies the recorded effects of earlier requests, so projected values take precedence.
        observe() {
          local endpoint=$1 fields=''${2-} body=''${3-} found=0 pending
          if [[ ''${presence[$endpoint]-} == absent ]]; then
            live='{}'
            return 1
          fi
          fetch "$endpoint" || found=1
          if [[ ''${presence[$endpoint]-} == present ]]; then
            found=0
          fi
          if ((found == 0)) && [[ -n $fields && $fields != "{}" ]]; then
            read_live_fields "$fields" "$body"
          fi
          pending=''${projected[$endpoint]-}
          if [[ -n $pending ]]; then
            live=$(jq --null-input --compact-output --argjson live "$live" --argjson pending "$pending" '$live + $pending')
          fi
          return "$found"
        }

        # The read_live_fields function replaces each body field in live with the value that another endpoint returns. The filter receives every page of the response as an array. An endpoint can answer HTTP 409 when the field does not apply, which counts as no value.
        # The caller runs in a condition, which disables errexit, so each command stops the switch explicitly. The records use NUL delimiters, so a filter can span lines.
        read_live_fields() {
          local fields=$1 body=$2 field source filter base=$live value pages
          while IFS= read -r -d "" field && IFS= read -r -d "" source && IFS= read -r -d "" filter; do
            if fetch "$source" '404|409'; then
              pages=$(gh api --paginate --slurp "$source") || {
                echo "octonix: cannot read every page of $source" >&2
                exit 1
              }
              value=$(jq --compact-output "$filter" <<<"$pages") || exit 1
            else
              value=null
            fi
            base=$(jq --null-input --compact-output --argjson base "$base" --arg field "$field" --argjson value "$value" '$base + {($field): $value}') || exit 1
          done < <(jq --join-output --argjson body "$body" 'to_entries[] | .key as $key | select($body | has($key)) | "\(.key)\u0000\(.value.endpoint)\u0000\(.value.filter)\u0000"' <<<"$fields")
          live=$base
        }

        reconcile() {
          local name=$1 method=$2 endpoint=$3 body=$4 skip_if_exists=$5
          local failure_method=$6 failure_endpoint=$7 failure_body=$8 creates=$9 live_fields=''${10}
          local action changes="" resource state found=0

          if [[ -n $skip_if_exists ]]; then
            if observe "$skip_if_exists"; then action=unchanged; else action=create; fi
          elif [[ $method == POST ]]; then
            action=create
          elif [[ $method == DELETE ]]; then
            if observe "$endpoint"; then action=delete; else action=unchanged; fi
          else
            observe "$endpoint" "$live_fields" "$body" || found=1
            changes=$(difference "$body")
            if ((found != 0)); then
              action=create
            elif [[ -z $changes ]]; then
              action=unchanged
            else
              action=change
            fi
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
            if [[ $action == create ]]; then
              while IFS=$'\t' read -r resource state; do
                presence[$resource]=present
                remember "$resource" "$state"
              done < <(jq --raw-output 'to_entries[] | "\(.key)\t\(.value | tojson)"' <<<"$creates")
            fi
            if [[ ($action == create || $action == change) && ($method == PATCH || $method == PUT) ]]; then
              presence[$endpoint]=present
              remember "$endpoint" "$body"
            fi
            if [[ $action == delete ]]; then
              presence[$endpoint]=absent
              unset 'projected[$endpoint]'
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
          (builtins.toJSON (request.creates or { }))
          (builtins.toJSON (request.liveFields or { }))
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

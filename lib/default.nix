# This library evaluates octonix modules and renders their requests into a switch script.
{ lib }:
{
  evalConfig =
    modules:
    (lib.evalModules {
      modules = [ ../modules ] ++ modules;
    }).config;

  # The schema function converts the module options into a JSON Schema, so an editor can validate and complete the TOML input.
  schema =
    let
      typeSchema =
        type:
        {
          nullOr = typeSchema type.nestedTypes.elemType;
          listOf = {
            type = "array";
            items = typeSchema type.nestedTypes.elemType;
          };
          attrsOf = {
            type = "object";
            additionalProperties = typeSchema type.nestedTypes.elemType;
          };
          bool.type = "boolean";
          int.type = "integer";
          str.type = "string";
          strMatching.type = "string";
          submodule = optionsSchema (type.getSubOptions [ ]);
          enum.enum = type.functor.payload.values;
        }
        .${type.name} or { };
      entrySchema =
        entry:
        if entry._type or null == "option" then
          typeSchema entry.type
          // lib.optionalAttrs (lib.isString (entry.description or null)) { inherit (entry) description; }
        else
          optionsSchema entry;
      optionsSchema = options: {
        type = "object";
        additionalProperties = false;
        properties = lib.mapAttrs (_: entrySchema) (
          lib.filterAttrs (
            key: entry: key != "_module" && !(entry.internal or false) && !(entry.readOnly or false)
          ) options
        );
      };
    in
    (optionsSchema (lib.evalModules { modules = [ ../modules ]; }).options)
    // {
      "$schema" = "http://json-schema.org/draft-07/schema#";
    };

  mkSwitch =
    pkgs: requests:
    pkgs.writeShellApplication {
      name = "octonix-switch";
      runtimeInputs = [
        pkgs.gh
        pkgs.jq
      ];
      text = ''
        check=0
        case "$*" in
          "") mode=switch ;;
          --build) mode=build ;;
          "--build --check") mode=build check=1 ;;
          *)
            echo "usage: octonix-switch [--build [--check]]" >&2
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
        declare -A projected=() presence=() listings=()

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

        # The pages_of function stores in pages every page of a listing as an array. It reads each listing once per run, and a write clears the cache. It returns 1 for an absent status, HTTP 404 by default, and stops the switch on any other failure.
        pages_of() {
          local source=$1 absent=''${2:-404} output
          if [[ -z ''${listings[$source]-} ]]; then
            if output=$(gh api --paginate --slurp "$source" 2>&1); then
              listings[$source]=$output
            elif [[ $output =~ HTTP\ ($absent) ]]; then
              listings[$source]=absent
            else
              printf 'octonix: cannot read every page of %s\n%s\n' "$source" "$output" >&2
              exit 1
            fi
          fi
          pages=''${listings[$source]}
          [[ $pages != absent ]]
        }

        # The read_live_fields function replaces each body field in live with the value that another endpoint returns. The filter receives every page of the response as an array. An endpoint can answer HTTP 409 when the field does not apply, which counts as no value.
        # The caller runs in a condition, which disables errexit, so each command stops the switch explicitly. The records use NUL delimiters, so a filter can span lines.
        read_live_fields() {
          local fields=$1 body=$2 field source filter base=$live value pages
          while IFS= read -r -d "" field && IFS= read -r -d "" source && IFS= read -r -d "" filter; do
            if pages_of "$source" '404|409'; then
              value=$(jq --compact-output "$filter" <<<"$pages") || exit 1
            else
              value=null
            fi
            base=$(jq --null-input --compact-output --argjson base "$base" --arg field "$field" --argjson value "$value" '$base + {($field): $value}') || exit 1
          done < <(jq --join-output --argjson body "$body" 'to_entries[] | .key as $key | select($body | has($key)) | "\(.key)\u0000\(.value.endpoint)\u0000\(.value.filter)\u0000"' <<<"$fields")
          live=$base
        }

        # The resolve function stores in identifier the value that the filter returns for every page of the listing. It stores an empty value when the listing is absent or the filter returns null.
        resolve() {
          local source=$1 filter=$2 pages
          identifier=""
          if pages_of "$source"; then
            identifier=$(jq --raw-output "($filter) // empty" <<<"$pages")
          fi
        }

        # The prune_items function deletes each live item that the configuration does not declare. The filter turns every page of the listing into an array of key and id records. The deleted item shows as a removal in build mode too, so a review comes before the switch.
        prune_items() {
          local name=$1 delete_endpoint=$2 list=$3 filter=$4 keep=$5 pages items key id
          if ! pages_of "$list"; then
            return
          fi
          items=$(jq --compact-output "$filter" <<<"$pages") || exit 1
          # shellcheck disable=SC2016
          while IFS=$'\t' read -r key id; do
            echo "''${red}- $name/$key''${reset}"
            deleted=$((deleted + 1))
            if [[ $mode == switch ]]; then
              gh api --method DELETE --silent "''${delete_endpoint//"{id}"/$id}"
              listings=()
            fi
          done < <(jq --raw-output --argjson keep "$keep" '.[] | select(.key as $key | $keep | index($key) | not) | "\(.key)\t\(.id)"' <<<"$items")
        }

        # The reconcile function receives one request as JSON. It reads each field with a NUL delimiter, so a filter can span lines.
        reconcile() {
          local name method endpoint body skip_if_exists failure_method failure_endpoint failure_body creates live_fields
          local lookup_endpoint lookup_filter create_method create_endpoint secret_repository secret_name
          local prune_endpoint prune_filter prune_keep
          {
            read -r -d "" name
            read -r -d "" method
            read -r -d "" endpoint
            read -r -d "" body
            read -r -d "" skip_if_exists
            read -r -d "" failure_method
            read -r -d "" failure_endpoint
            read -r -d "" failure_body
            read -r -d "" creates
            read -r -d "" live_fields
            read -r -d "" lookup_endpoint
            read -r -d "" lookup_filter
            read -r -d "" create_method
            read -r -d "" create_endpoint
            read -r -d "" secret_repository
            read -r -d "" secret_name
            read -r -d "" prune_endpoint
            read -r -d "" prune_filter
            read -r -d "" prune_keep
          } < <(jq --join-output '
            [
              .name, .method, .endpoint, (.body // {} | tojson), (.skipIfExists // ""),
              (.onFailure.method // ""), (.onFailure.endpoint // ""), (.onFailure.body // {} | tojson),
              (.creates // {} | tojson), (.liveFields // {} | tojson),
              (.lookup.endpoint // ""), (.lookup.filter // ""), (.lookup.createMethod // ""), (.lookup.createEndpoint // ""),
              (.environmentSecret.repository // ""), (.environmentSecret.name // ""),
              (.prune.endpoint // ""), (.prune.filter // ""), (.prune.keep // [] | tojson)
            ][] | . + "\u0000"
          ' <<<"$1")

          if [[ -n $prune_endpoint ]]; then
            prune_items "$name" "$endpoint" "$prune_endpoint" "$prune_filter" "$prune_keep"
            return
          fi
          local action="" changes="" resource state found=0

          if [[ -n $lookup_endpoint ]]; then
            resolve "$lookup_endpoint" "$lookup_filter"
            if [[ -n $identifier ]]; then
              endpoint=''${endpoint//"{id}"/$identifier}
            else
              action=create method=$create_method endpoint=$create_endpoint
            fi
          fi

          if [[ -n $action ]]; then
            :
          elif [[ -n $skip_if_exists ]]; then
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

          # A secret value comes from the environment variable with the name of the secret. The switch script never reads the value back from GitHub, so it sets only a missing secret.
          if [[ -n $secret_name && $action == create && -z ''${!secret_name-} ]]; then
            echo "octonix: set the environment variable $secret_name to create the secret" >&2
            exit 1
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

          if [[ $action != unchanged && -n $secret_name ]]; then
            gh secret set "$secret_name" --repo "$secret_repository" --body "''${!secret_name}"
            listings=()
          elif [[ $action != unchanged ]]; then
            printf '%s' "$body" | gh api --method "$method" --input - --silent "$endpoint"
            listings=()
          fi
          # The cleanup also covers a request that was already satisfied, because a later failure can still leave the wrong state.
          if [[ -n $failure_method ]]; then
            cleanups+=("$failure_method" "$failure_endpoint" "$failure_body")
          fi
        }

      ''
      + lib.concatMapStringsSep "\n" (
        request:
        lib.escapeShellArgs [
          "reconcile"
          (builtins.toJSON request)
        ]
      ) requests
      + ''

        if [[ $mode == build ]]; then
          echo "Build: $created to create, $changed to change, $deleted to delete, $unchanged unchanged."
          # With --check, pending changes exit with status 3, so a CI job can report drift.
          if ((check == 1 && created + changed + deleted > 0)); then
            exit 3
          fi
        else
          echo "Switch: $created created, $changed changed, $deleted deleted, $unchanged unchanged."
        fi
      '';
    };
}

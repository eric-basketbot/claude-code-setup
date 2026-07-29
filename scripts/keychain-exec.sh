#!/bin/zsh -f
unsetopt XTRACE VERBOSE 2>/dev/null || true
set -euo pipefail

if (( $# < 4 )); then
  print -u2 'usage: keychain-exec.sh SERVICE VARIABLE [--validate-only] -- COMMAND [ARG ...]'
  exit 64
fi

service_name="$1"
variable_name="$2"
shift 2

validate_only=0
inject_stitch_header=0
if [[ "${1:-}" == "--validate-only" ]]; then
  validate_only=1
  shift
fi

[[ "$1" == "--" ]] || {
  print -u2 'keychain-exec: missing command separator'
  exit 64
}
shift
(( $# >= 1 )) || {
  print -u2 'keychain-exec: missing command'
  exit 64
}

case "${service_name}|${variable_name}" in
  ai-config.global.GRAFANA_SERVICE_ACCOUNT_TOKEN\|GRAFANA_SERVICE_ACCOUNT_TOKEN | \
  ai-config.myproject.BASKETBOT_GRAFANA_SERVICE_ACCOUNT_TOKEN\|BASKETBOT_GRAFANA_SERVICE_ACCOUNT_TOKEN | \
  ai-config.myproject.STITCH_API_KEY\|STITCH_API_KEY)
    ;;
  *)
    print -u2 'keychain-exec: credential mapping is not allowlisted'
    exit 65
    ;;
esac

case "${service_name}|${variable_name}" in
  ai-config.global.GRAFANA_SERVICE_ACCOUNT_TOKEN\|GRAFANA_SERVICE_ACCOUNT_TOKEN | \
  ai-config.myproject.BASKETBOT_GRAFANA_SERVICE_ACCOUNT_TOKEN\|BASKETBOT_GRAFANA_SERVICE_ACCOUNT_TOKEN)
    if (( $# != 3 )) || [[ "$1" != "/opt/homebrew/bin/mcp-grafana" || "$2" != "-t" || "$3" != "stdio" ]]; then
      print -u2 'keychain-exec: command does not match the credential policy'
      exit 65
    fi
    ;;
  ai-config.myproject.STITCH_API_KEY\|STITCH_API_KEY)
    if (( $# != 5 )) || \
       [[ "$1" != "/usr/local/bin/npx" || \
          "$2" != "-y" || \
          "$3" != "mcp-remote@0.1.38" || \
          "$4" != "https://stitch.googleapis.com/mcp" || \
          "$5" != "--silent" ]]; then
      print -u2 'keychain-exec: command does not match the credential policy'
      exit 65
    fi
    inject_stitch_header=1
    ;;
esac

if (( validate_only )); then
  exit 0
fi

security_bin="/usr/bin/security"
id_bin="/usr/bin/id"
[[ -x "$security_bin" ]] || {
  print -u2 'keychain-exec: security helper is unavailable'
  exit 69
}
[[ -x "$id_bin" ]] || {
  print -u2 'keychain-exec: account helper is unavailable'
  exit 69
}
account_name="$("$id_bin" -un)"
[[ -n "$account_name" ]] || {
  print -u2 'keychain-exec: account lookup failed'
  exit 69
}

secret_value="$(
  "$security_bin" find-generic-password \
    -a "$account_name" \
    -s "$service_name" \
    -w
)"
[[ -n "$secret_value" ]] || {
  print -u2 'keychain-exec: Keychain value is empty'
  exit 69
}

for argument in "$@"; do
  if [[ "$argument" == *"$secret_value"* ]]; then
    print -u2 'keychain-exec: refusing credential in process arguments'
    unset secret_value
    exit 65
  fi
done

if (( inject_stitch_header )); then
  set -- "$1" "$2" "$3" "$4" \
    "--header" 'X-Goog-Api-Key:${STITCH_API_KEY}' "$5"
fi

typeset -gx "$variable_name=$secret_value"
unset secret_value service_name variable_name security_bin id_bin account_name validate_only inject_stitch_header
exec "$@"

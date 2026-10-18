# Resolves per-environment paths. Sourced, not executed.
#
# Two environments share this repository:
#
#   local     the working consortium, holding real chain state
#   staging   a rehearsal stack, isolated by subnet, ports and compose project
#
# Staging exists because the m9 runbook is a deliverable, and a runbook nobody
# has executed is fiction. Procedures like recovering a stalled QBFT round can
# only be written by deliberately stalling one, which cannot happen on the
# network holding demo state.
#
# What differs between environments: chain material (genesis, node keys),
# addressing, and compose project. What is shared: the PKI. Node names are
# identical in both because the roles are identical, so a second certificate
# tree would be work without insight.
#
# Select with LOC_ENV, defaulting to local, so every existing command keeps
# working untouched.

LOC_ENV="${LOC_ENV:-local}"

case "$LOC_ENV" in
  local|staging) ;;
  *) echo "unknown LOC_ENV: $LOC_ENV (expected local or staging)" >&2; return 1 2>/dev/null || exit 1 ;;
esac

env_init() {
  local repo="$1"
  ENV_NAME="$LOC_ENV"
  ENV_GENESIS_DIR="$repo/network/genesis/$LOC_ENV"
  ENV_KEYS_DIR="$repo/network/keys/$LOC_ENV"
  ENV_CONFIG_DIR="$repo/network/config/$LOC_ENV"
  ENV_ADDRESSING="$ENV_CONFIG_DIR/addressing.conf"
  ENV_MANIFEST="$ENV_GENESIS_DIR/manifest.json"
  ENV_GENESIS="$ENV_GENESIS_DIR/genesis.json"
  ENV_STATIC_NODES="$ENV_CONFIG_DIR/static-nodes.json"
  ENV_DEPLOY_CONFIG="$ENV_CONFIG_DIR/deploy.json"
  ENV_COMPOSE_OVERRIDE="$repo/network/compose/compose.$LOC_ENV.yml"
  ENV_PROJECT="loc-$LOC_ENV"
}

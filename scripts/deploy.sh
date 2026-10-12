#!/usr/bin/env bash
# Copyright 2026 DataRobot, Inc. and its affiliates.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# The steps of the reusable deploy workflow, one function each:
#
#   scripts/deploy.sh <step>
#
# Nothing here depends on one CI host. A step writes its results through
# emit_output and emit_summary, which append to DEPLOY_OUTPUT_FILE and
# DEPLOY_SUMMARY_FILE. When unset they fall back to GITHUB_OUTPUT and
# GITHUB_STEP_SUMMARY, then to stdout and stderr. A wrapper for another host
# sets the two variables.
#
# Environment:
#   MODE                  plan or apply
#   TARGET                folder under environments/ that holds the manifest
#   DEPLOY_DIR            directory of the deploy config with VERSION, environments/ and overrides/
#   LOCK                  true to lock the artifact on apply
#   CONFIG_DIR            checkout of the deploy config (default deploy-config)
#   APP_DIR               checkout of labs-hermes (default app)
#   WORK_DIR              scratch directory (default $TMPDIR or /tmp)
#   DATAROBOT_API_TOKEN   read by run_up only
#   DR_CLI_VERSION, DR_CLI_INSTALLER_REF, DR_BIN_DIR   read by install_dr only

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-deploy-config}"
APP_DIR="${APP_DIR:-app}"
WORK_DIR="${WORK_DIR:-${TMPDIR:-/tmp}}"

# Only these paths of overrides/config can replace a file in the upstream config/.
# The Dockerfile, docker/, the OTel template and .drsyncignore carry the read-only
# filesystem and the state protection.
ALLOWED_OVERRIDES=(SOUL.md skills config.yaml requirements.txt)

fail() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::error::%s\n' "$*" >&2
  else
    printf 'error: %s\n' "$*" >&2
  fi
  exit 1
}

emit_output() {
  printf '%s=%s\n' "$1" "$2" >> "${DEPLOY_OUTPUT_FILE:-${GITHUB_OUTPUT:-/dev/stdout}}"
}

# Reads markdown from stdin.
emit_summary() {
  cat >> "${DEPLOY_SUMMARY_FILE:-${GITHUB_STEP_SUMMARY:-/dev/stderr}}"
}

deploy::check_inputs() {
  case "${MODE:-}" in
    plan | apply) ;;
    *) fail "mode must be plan or apply" ;;
  esac
  case "${TARGET:-}" in
    '' | *[!a-z0-9-]*) fail "target must match [a-z0-9-]+" ;;
  esac
  case "${DEPLOY_DIR:-}" in
    '' | /* | *..*) fail "deploy-dir must be a relative path without .." ;;
  esac
}

# Emits ref, the tag or commit of labs-hermes to deploy.
deploy::read_version() {
  local file="${CONFIG_DIR}/${DEPLOY_DIR}/VERSION" ref
  [ -f "${file}" ] || fail "${DEPLOY_DIR}/VERSION is missing"
  ref=$(tr -d '[:space:]' < "${file}")
  if ! printf '%s' "${ref}" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$|^[0-9a-f]{40}$'; then
    fail "VERSION must hold a vX.Y.Z tag or a 40 character commit SHA"
  fi
  emit_output ref "${ref}"
}

# Copies the overrides over the upstream config/ and places the target's manifest.
deploy::apply_overrides() {
  local overrides="${CONFIG_DIR}/${DEPLOY_DIR}/overrides/config"
  local manifest="${CONFIG_DIR}/${DEPLOY_DIR}/environments/${TARGET}/.datarobot.yaml"
  local entry name allowed ok
  if [ -d "${overrides}" ]; then
    # A symlink can point at a protected path or outside the checkout, and -e skips a dangling one.
    if [ -n "$(find "${overrides}" -type l -print -quit)" ]; then
      fail "overrides/config must not contain symbolic links"
    fi
    for entry in "${overrides}"/* "${overrides}"/.[!.]*; do
      [ -e "${entry}" ] || continue
      name=$(basename "${entry}")
      ok=false
      for allowed in "${ALLOWED_OVERRIDES[@]}"; do
        [ "${name}" = "${allowed}" ] && ok=true
      done
      "${ok}" || fail "overrides/config/${name} cannot be overridden"
    done
    cp -R "${overrides}"/. "${APP_DIR}/config/"
  fi
  [ -f "${manifest}" ] || fail "${DEPLOY_DIR}/environments/${TARGET}/.datarobot.yaml is missing"
  [ ! -L "${manifest}" ] || fail "${DEPLOY_DIR}/environments/${TARGET}/.datarobot.yaml must not be a symbolic link"
  cp "${manifest}" "${APP_DIR}/.datarobot.yaml"
}

# Installs the pinned dr CLI into DR_BIN_DIR. The caller puts that directory on PATH.
deploy::install_dr() {
  : "${DR_CLI_VERSION:?}" "${DR_CLI_INSTALLER_REF:?}"
  local bin_dir="${DR_BIN_DIR:-${WORK_DIR}/bin}" installer="${WORK_DIR}/install-dr.sh"
  mkdir -p "${bin_dir}"
  curl -fsSL -o "${installer}" \
    "https://raw.githubusercontent.com/datarobot-oss/cli/${DR_CLI_INSTALLER_REF}/install.sh"
  INSTALL_DIR="${bin_dir}" sh "${installer}" "${DR_CLI_VERSION}"
}

# Plans or applies, writes the output of dr to the summary and emits workload-id.
# Returns the exit status of dr, after it has written the summary.
deploy::run_up() {
  [ -n "${DATAROBOT_API_TOKEN:-}" ] || fail "DATAROBOT_API_TOKEN is empty. Set it for the ${TARGET} environment."
  local log="${WORK_DIR}/up.log" args=(--yes --dir "${APP_DIR}") status version id
  if [ "${MODE}" = plan ]; then
    args+=(--dry-run)
  elif [ "${LOCK:-}" = true ]; then
    args+=(--lock)
  fi
  dr --version
  set +e
  dr workload up "${args[@]}" 2>&1 | tee "${log}"
  status="${PIPESTATUS[0]}"
  set -e
  version=$(tr -d '[:space:]' < "${CONFIG_DIR}/${DEPLOY_DIR}/VERSION")
  {
    echo "### dr workload up (${MODE}, ${TARGET}, ${version})"
    echo '```text'
    tail -n 200 "${log}"
    echo '```'
  } | emit_summary
  id=$(sed -nE 's/^workloadId: *([0-9a-f]+).*/\1/p' "${APP_DIR}/.datarobot.yaml" | head -n 1)
  emit_output workload-id "${id}"
  return "${status}"
}

# A first deploy writes workloadId into the manifest. Emits manifest-changed and,
# when it changed, manifest-path with a copy to upload. Commit it, or the next run
# creates another workload.
deploy::keep_manifest() {
  local original="${CONFIG_DIR}/${DEPLOY_DIR}/environments/${TARGET}/.datarobot.yaml"
  local copy="${WORK_DIR}/manifest-${TARGET}.yaml"
  if cmp -s "${original}" "${APP_DIR}/.datarobot.yaml"; then
    emit_output manifest-changed false
    return 0
  fi
  cp "${APP_DIR}/.datarobot.yaml" "${copy}"
  emit_output manifest-changed true
  emit_output manifest-path "${copy}"
  {
    echo '> [!IMPORTANT]'
    echo "> The run changed the manifest. Commit the \`manifest-${TARGET}\` artifact to \`${DEPLOY_DIR}/environments/${TARGET}/.datarobot.yaml\`, or the next deploy creates another workload."
  } | emit_summary
}

main() {
  local step="${1:-}"
  declare -F "deploy::${step}" > /dev/null || fail "unknown step '${step}'. Steps: check_inputs read_version apply_overrides install_dr run_up keep_manifest"
  "deploy::${step}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

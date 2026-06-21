#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config_path="${script_dir}/../config/tools.yaml"
platform_name="linux"
arg_delimiter=$'\034'
readonly TOOL_VERSION_FALLBACK="v1.4.1"

script_version() {
  local repo_root
  local version

  repo_root="$(cd "${script_dir}/.." && pwd -P)"

  if command -v git >/dev/null 2>&1 && [[ -d "${repo_root}/.git" ]]; then
    if version="$(git -C "${repo_root}" describe --tags --long --always --dirty 2>/dev/null)"; then
      if [[ -n "${version}" ]]; then
        printf '%s' "${version}"
        return 0
      fi
    fi
  fi

  printf '%s' "${TOOL_VERSION_FALLBACK}"
}

TOOL_VERSION="$(script_version)"
readonly TOOL_VERSION
verbose=0
dry_run=0
check_path=0
remove_mode=0
help_requested=0
prefix_root=""

tool_ids=()
tool_executables=()
tool_version_checks=()
tool_version_args=()
installer_kinds=()
installer_packages=()
installer_urls=()
installer_file_names=()
installer_archive_kinds=()
installer_archive_paths=()
installer_owners=()
installer_repos=()
installer_asset_patterns=()
installer_executables=()
installer_install_dir_names=()
installer_bin_paths=()
installer_source_dirs=()

usage() {
  printf 'Coding Agent Toolchain %s\n' "${TOOL_VERSION}"
  printf '\n'
  printf 'Usage: %s [-c|--config PATH] [-v|--verbose] [-d|--dry-run] [-r|--remove] [--check-path] [-p|--prefix PATH] [-h|--help]\n' "${0##*/}"
  printf '\n'
  printf 'Options:\n'
  printf '  -c, --config PATH  Use a custom YAML manifest path.\n'
  printf '  -v, --verbose      Print detailed debug traces.\n'
  printf '  -d, --dry-run      Simulate a successful run without modifications.\n'
  printf '  -r, --remove       Remove tools previously installed by coding-agent-toolchain.\n'
  printf '      --check-path   Verify resolved tool directories in PATH.\n'
  printf '  -p, --prefix PATH  Install missing tools under PATH/coding-agent-toolchain.\n'
  printf '  -h, --help         Show this help and version.\n'
}

log_info() {
  printf '[INFO ] %s\n' "$*" >&2
}

log_warning() {
  printf '[WARN ] %s\n' "$*" >&2
}

log_verbose() {
  if ((verbose)); then
    printf '[DEBUG] %s\n' "$*" >&2
  fi
}

log_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

is_root_identity() {
  if [[ "${CAT_TEST_FORCE_ROOT:-}" == "1" ]]; then
    return 0
  fi

  [[ "$(id -u)" == "0" ]]
}

ensure_public_mode_allowed() {
  if is_root_identity; then
    log_error "Coding Agent Toolchain cannot run as root."
    return 2
  fi
}

trim_manifest_value() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"

  if [[ ${#value} -ge 2 ]]; then
    local first="${value:0:1}"
    local last="${value: -1}"
    if [[ "${first}" == "'" && "${last}" == "'" ]] || [[ "${first}" == '"' && "${last}" == '"' ]]; then
      value="${value:1:${#value}-2}"
    fi
  fi

  printf '%s' "${value}"
}

set_installer_value() {
  local index="$1"
  local key="$2"
  local value="$3"

  case "${key}" in
  kind) installer_kinds[index]="${value}" ;;
  package) installer_packages[index]="${value}" ;;
  url) installer_urls[index]="${value}" ;;
  file_name) installer_file_names[index]="${value}" ;;
  archive_kind) installer_archive_kinds[index]="${value}" ;;
  archive_path) installer_archive_paths[index]="${value}" ;;
  owner) installer_owners[index]="${value}" ;;
  repo) installer_repos[index]="${value}" ;;
  asset_pattern) installer_asset_patterns[index]="${value}" ;;
  executable) installer_executables[index]="${value}" ;;
  install_dir_name) installer_install_dir_names[index]="${value}" ;;
  bin_path) installer_bin_paths[index]="${value}" ;;
  source_dir) installer_source_dirs[index]="${value}" ;;
  *)
    log_error "Unsupported installer key '${key}'."
    return 1
    ;;
  esac
}

read_manifest() {
  local path="$1"
  local line
  local line_number=0
  local schema_version=""
  local current_index=-1
  local current_section=""
  local current_os=""

  if [[ ! -f "${path}" ]]; then
    log_error "Configuration file not found: ${path}"
    return 1
  fi

  log_verbose "Opening configuration file: ${path}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line_number=$((line_number + 1))
    line="${line%$'\r'}"

    if [[ "${line}" =~ ^[[:space:]]*$ ]] || [[ "${line}" =~ ^[[:space:]]*# ]]; then
      continue
    fi

    if [[ "${line}" =~ ^schema_version:[[:space:]]*(.+)$ ]]; then
      schema_version="$(trim_manifest_value "${BASH_REMATCH[1]}")"
      continue
    fi

    if [[ "${line}" =~ ^tools:[[:space:]]*$ ]]; then
      current_section="tools"
      continue
    fi

    if [[ "${line}" =~ ^[[:space:]][[:space:]]-[[:space:]]id:[[:space:]]*(.+)$ ]]; then
      current_index=$((${#tool_ids[@]}))
      tool_ids[current_index]="$(trim_manifest_value "${BASH_REMATCH[1]}")"
      log_verbose "Reading manifest entry for tool '${tool_ids[current_index]}'."
      tool_executables[current_index]=""
      tool_version_checks[current_index]="command"
      tool_version_args[current_index]=""
      installer_kinds[current_index]=""
      installer_packages[current_index]=""
      installer_urls[current_index]=""
      installer_file_names[current_index]=""
      installer_archive_kinds[current_index]=""
      installer_archive_paths[current_index]=""
      installer_owners[current_index]=""
      installer_repos[current_index]=""
      installer_asset_patterns[current_index]=""
      installer_executables[current_index]=""
      installer_install_dir_names[current_index]=""
      installer_bin_paths[current_index]=""
      installer_source_dirs[current_index]=""
      current_section="tool"
      current_os=""
      continue
    fi

    if ((current_index < 0)); then
      log_error "Unsupported manifest line ${line_number} before the first tool: ${line}"
      return 1
    fi

    if [[ "${line}" =~ ^[[:space:]]{4}executable:[[:space:]]*(.+)$ ]]; then
      tool_executables[current_index]="$(trim_manifest_value "${BASH_REMATCH[1]}")"
      continue
    fi

    if [[ "${line}" =~ ^[[:space:]]{4}version_check:[[:space:]]*(.+)$ ]]; then
      tool_version_checks[current_index]="$(trim_manifest_value "${BASH_REMATCH[1]}")"
      continue
    fi

    if [[ "${line}" =~ ^[[:space:]]{4}version_args:[[:space:]]*$ ]]; then
      current_section="version_args"
      continue
    fi

    if [[ "${line}" =~ ^[[:space:]]{6}-[[:space:]](.+)$ && "${current_section}" == "version_args" ]]; then
      local arg
      arg="$(trim_manifest_value "${BASH_REMATCH[1]}")"
      if [[ -z "${tool_version_args[current_index]}" ]]; then
        tool_version_args[current_index]="${arg}"
      else
        tool_version_args[current_index]+="${arg_delimiter}${arg}"
      fi
      continue
    fi

    if [[ "${line}" =~ ^[[:space:]]{4}installers:[[:space:]]*$ ]]; then
      current_section="installers"
      current_os=""
      continue
    fi

    if [[ "${line}" =~ ^[[:space:]]{6}([a-z_]+):[[:space:]]*(.+)$ && "${current_section}" == "installers" ]]; then
      log_error "Installer property without platform at manifest line ${line_number}."
      return 1
    fi

    if [[ "${line}" =~ ^[[:space:]]{6}(windows|linux):[[:space:]]*$ ]]; then
      current_os="${BASH_REMATCH[1]}"
      current_section="installer"
      continue
    fi

    if [[ "${line}" =~ ^[[:space:]]{8}([a-z_]+):[[:space:]]*(.+)$ && "${current_section}" == "installer" ]]; then
      local key
      local value
      key="${BASH_REMATCH[1]}"
      value="$(trim_manifest_value "${BASH_REMATCH[2]}")"

      if [[ "${current_os}" == "${platform_name}" ]]; then
        set_installer_value "${current_index}" "${key}" "${value}" || return 1
      fi
      continue
    fi

    log_error "Unsupported manifest line ${line_number}: ${line}"
    return 1
  done <"${path}"

  if [[ "${schema_version}" != "1" ]]; then
    log_error "Unsupported schema_version '${schema_version}'. Expected '1'."
    return 1
  fi

  if ((${#tool_ids[@]} == 0)); then
    log_error "The manifest does not define any tools."
    return 1
  fi

  log_verbose "Manifest schema version '${schema_version}' contains ${#tool_ids[@]} tool entries."
  local index
  for index in "${!tool_ids[@]}"; do
    if [[ -z "${tool_ids[index]}" ]]; then
      log_error "Every tool entry must define an id."
      return 1
    fi

    if [[ -z "${tool_executables[index]}" ]]; then
      log_error "Tool '${tool_ids[index]}' must define an executable."
      return 1
    fi

    case "${tool_version_checks[index]}" in
    command | command_available) ;;
    *)
      log_error "Tool '${tool_ids[index]}' defines unsupported version_check '${tool_version_checks[index]}'."
      return 1
      ;;
    esac

    if [[ -z "${installer_kinds[index]}" ]]; then
      installer_kinds[index]="unavailable"
      log_verbose "Tool '${tool_ids[index]}' does not define a Linux installer and will be skipped."
    fi
  done

  apply_manifest_defaults
}

apply_manifest_defaults() {
  local index

  for index in "${!tool_ids[@]}"; do
    if [[ "${tool_ids[index]}" == "ghostscript" ]]; then
      if [[ "${installer_kinds[index]}" == "conda_forge" ]]; then
        log_info "Configuring Ghostscript Linux installer to prefer 'source_make' with 'conda_forge' fallback."
        installer_kinds[index]="source_make"
      fi
      installer_packages[index]="ghostscript"
      installer_owners[index]="${installer_owners[index]:-ArtifexSoftware}"
      installer_repos[index]="${installer_repos[index]:-ghostpdl-downloads}"
      installer_asset_patterns[index]="${installer_asset_patterns[index]:-ghostscript-[0-9.]+[.]tar[.]xz}"
      installer_source_dirs[index]="${installer_source_dirs[index]:-ghostscript-*}"
      installer_install_dir_names[index]="${installer_install_dir_names[index]:-ghostscript}"
      installer_bin_paths[index]="${installer_bin_paths[index]:-bin}"
    fi
  done
}

require_installer_value() {
  local value="$1"
  local name="$2"
  local tool_id="$3"

  if [[ -z "${value}" ]]; then
    log_error "Installer for tool '${tool_id}' must define '${name}'."
    return 1
  fi

  printf '%s' "${value}"
}

tool_executable() {
  local index="$1"
  if [[ -n "${installer_executables[index]}" ]]; then
    printf '%s' "${installer_executables[index]}"
  else
    printf '%s' "${tool_executables[index]}"
  fi
}

platform_display_name() {
  case "${platform_name}" in
  linux) printf 'Linux' ;;
  windows) printf 'Windows' ;;
  *) printf '%s' "${platform_name}" ;;
  esac
}

is_tool_supported_on_platform() {
  local index="$1"

  case "${installer_kinds[index]}" in
  '' | unavailable | unsupported | none) return 1 ;;
  *) return 0 ;;
  esac
}

unsupported_tool_detail() {
  local index="$1"

  printf "Tool '%s' is not available on %s. Skipping installation." \
    "${tool_ids[index]}" \
    "$(platform_display_name)"
}

is_pwsh_usable() {
  command -v pwsh >/dev/null 2>&1 || return 1
  pwsh -NoProfile -Command "\$PSVersionTable.PSVersion.ToString()" >/dev/null 2>&1
}

missing_prerequisite_detail() {
  local index="$1"

  if [[ "${installer_kinds[index]}" == "powershell_gallery" ]] && ! is_pwsh_usable; then
    printf "Tool '%s' requires pwsh on Linux, but pwsh is not available or usable. Skipping installation." \
      "${tool_ids[index]}"
    return 0
  fi

  return 1
}

dry_run_tool() {
  local index="$1"
  local executable
  local verification_method="its configured version command"

  executable="$(tool_executable "${index}")"
  if [[ "${tool_version_checks[index]}" == "command_available" ]]; then
    verification_method="executable availability"
  fi

  log_info "Dry-run: would check executable '${executable}' for tool '${tool_ids[index]}'."
  log_info "Dry-run: would install '${tool_ids[index]}' if required using '${installer_kinds[index]}'."
  log_info "Dry-run: would verify '${tool_ids[index]}' with ${verification_method}."
  log_info "Dry-run: would write an installation marker after a successful install."

  if [[ -n "${installer_packages[index]}" ]]; then
    log_verbose "Dry-run package for '${tool_ids[index]}': ${installer_packages[index]}"
  fi

  if [[ -n "${installer_urls[index]}" ]]; then
    log_verbose "Dry-run download URL for '${tool_ids[index]}': ${installer_urls[index]}"
  fi

  if [[ "${tool_ids[index]}" == "ghostscript" && "${installer_kinds[index]}" == "source_make" ]]; then
    if c_compiler_command >/dev/null 2>&1; then
      log_info "Dry-run: would build Ghostscript from source because a C compiler is available."
    else
      log_info "Dry-run: would use the conda-forge fallback because no C compiler is available."
    fi
  fi
}

normalize_prefix_root() {
  local value="$1"

  while [[ "${value}" != "/" && "${value}" == */ ]]; do
    value="${value%/}"
  done

  printf '%s' "${value}"
}

xdg_data_home() {
  if [[ -n "${XDG_DATA_HOME:-}" && "${XDG_DATA_HOME}" == /* ]]; then
    printf '%s' "${XDG_DATA_HOME}"
  else
    printf '%s/.local/share' "${HOME}"
  fi
}

normalize_absolute_path_text() {
  local path="$1"
  local normalized_path=""
  local segment
  local -a path_segments=()
  local -a normalized_segments=()

  path="$(normalize_prefix_root "${path}")"
  path="${path#/}"
  IFS='/' read -r -a path_segments <<<"${path}"

  for segment in "${path_segments[@]}"; do
    case "${segment}" in
    '' | .) ;;
    ..)
      if ((${#normalized_segments[@]} > 0)); then
        unset "normalized_segments[$((${#normalized_segments[@]} - 1))]"
      fi
      ;;
    *) normalized_segments+=("${segment}") ;;
    esac
  done

  for segment in "${normalized_segments[@]}"; do
    normalized_path+="/${segment}"
  done

  printf '%s' "${normalized_path:-/}"
}

resolve_directory_path_candidate() {
  local base_physical
  local candidate
  local path="$1"
  local suffix=""

  path="$(normalize_absolute_path_text "${path}")"
  candidate="${path}"
  while [[ "${candidate}" != "/" && ! -e "${candidate}" ]]; do
    suffix="/${candidate##*/}${suffix}"
    candidate="${candidate%/*}"
    [[ -n "${candidate}" ]] || candidate="/"
  done

  if [[ -d "${candidate}" ]]; then
    base_physical="$(physical_directory "${candidate}")" || return 1
    base_physical="$(normalize_absolute_path_text "${base_physical}")"
  else
    base_physical="$(normalize_absolute_path_text "${candidate}")"
  fi

  if [[ "${base_physical}" == "/" ]]; then
    printf '%s' "${suffix:-/}"
  else
    printf '%s%s' "${base_physical}" "${suffix}"
  fi
}

toolchain_user_root() {
  if [[ -n "${prefix_root}" ]]; then
    if [[ "${prefix_root}" == "/" ]]; then
      printf '/coding-agent-toolchain'
    else
      printf '%s/coding-agent-toolchain' "${prefix_root}"
    fi
    return
  fi

  printf '%s/coding-agent-toolchain' "$(xdg_data_home)"
}

toolchain_platform_key() {
  local machine

  machine="$(uname -m 2>/dev/null || printf 'unknown')"
  if [[ -z "${machine}" ]]; then
    machine="unknown"
  fi

  printf '%s-%s' "${platform_name}" "${machine}"
}

toolchain_payload_root() {
  if [[ -n "${prefix_root}" ]]; then
    toolchain_user_root
  else
    printf '%s/tools/%s' "$(toolchain_user_root)" "$(toolchain_platform_key)"
  fi
}

tool_binary_dir() {
  local index="$1"

  printf '%s/bin' "$(install_directory "${index}")"
}

user_command_dir() {
  printf '%s/.local/bin' "${HOME}"
}

tool_command_dir() {
  local index="$1"

  if [[ -n "${prefix_root}" ]]; then
    tool_binary_dir "${index}"
  else
    user_command_dir
  fi
}

npm_prefix_dir() {
  local index="$1"

  install_directory "${index}"
}

npm_bin_dir() {
  local index="$1"

  printf '%s/bin' "$(npm_prefix_dir "${index}")"
}

npm_command_dir() {
  local index="$1"

  if [[ -n "${prefix_root}" ]]; then
    npm_bin_dir "${index}"
  else
    user_command_dir
  fi
}

uses_published_command() {
  local index="$1"

  if [[ -n "${prefix_root}" ]]; then
    return 1
  fi

  case "${installer_kinds[index]}" in
  npm_global | direct_binary | github_release_asset | uv_tool | appimage_extract | conda_forge | source_make) return 0 ;;
  *) return 1 ;;
  esac
}

install_directory() {
  local index="$1"
  local payload_root
  local directory_name="${installer_install_dir_names[index]:-${tool_ids[index]}}"

  payload_root="$(toolchain_payload_root)"
  printf '%s/%s' "${payload_root}" "${directory_name}"
}

node_install_directory() {
  printf '%s/node' "$(toolchain_payload_root)"
}

node_bin_dir() {
  printf '%s/bin' "$(node_install_directory)"
}

micromamba_install_directory() {
  printf '%s/micromamba' "$(toolchain_payload_root)"
}

micromamba_root_prefix() {
  printf '%s/micromamba-root' "$(toolchain_payload_root)"
}

micromamba_bin_path() {
  printf '%s/bin/micromamba' "$(micromamba_install_directory)"
}

ensure_directory() {
  local path="$1"
  if [[ -d "${path}" ]]; then
    log_verbose "Directory already exists: ${path}"
  else
    log_verbose "Creating directory: ${path}"
    mkdir -p -- "${path}"
  fi
}

install_marker_username() {
  local username="${USER:-${USERNAME:-}}"

  if [[ -z "${username}" ]]; then
    username="$(id -un 2>/dev/null || printf 'unknown')"
  fi

  printf '%s' "${username}"
}

install_marker_content() {
  printf 'Installed by coding-agent-toolchain %s (%s)' \
    "$(date '+%Y-%m-%d %H:%M:%S')" \
    "$(install_marker_username)"
}

write_install_marker() {
  local directory="$1"
  local normalized_directory
  local marker_path

  if [[ -z "${directory}" ]]; then
    log_error "Cannot write installation marker because the tool directory is empty."
    return 1
  fi

  normalized_directory="${directory%/}"
  if [[ -z "${normalized_directory}" ]]; then
    normalized_directory="/"
  fi

  ensure_directory "${normalized_directory}"
  marker_path="${normalized_directory}/.coding-agent-toolchain"
  log_verbose "Writing installation marker '${marker_path}'."
  if ! printf '%s\n' "$(install_marker_content)" >"${marker_path}"; then
    log_error "Failed to write installation marker '${marker_path}'."
    return 1
  fi

  log_info "Wrote installation marker: ${marker_path}"
}

install_marker_directory() {
  local index="$1"
  local executable_directory="$2"
  local install_dir

  case "${installer_kinds[index]}" in
  conda_forge | source_make | appimage_extract | portable_archive | direct_installer)
    install_directory "${index}"
    ;;
  npm_global)
    npm_prefix_dir "${index}"
    ;;
  pip | python_user)
    install_dir="$(install_directory "${index}")"
    if [[ -e "$(python_tool_bin_dir "${index}")/$(tool_executable "${index}")" ]]; then
      printf '%s' "${install_dir}"
    elif [[ -z "${executable_directory}" ]]; then
      printf '%s' "${install_dir}"
    else
      case "${executable_directory%/}/" in
      "${install_dir%/}/"*) printf '%s' "${install_dir}" ;;
      *) printf '%s' "${executable_directory%/}" ;;
      esac
    fi
    ;;
  direct_binary | github_release_asset | uv_tool)
    install_directory "${index}"
    ;;
  *)
    printf '%s' "${executable_directory%/}"
    ;;
  esac
}

write_install_marker_for_tool() {
  local index="$1"
  local executable_directory="$2"
  local marker_directory

  marker_directory="$(install_marker_directory "${index}" "${executable_directory}")"
  write_install_marker "${marker_directory}"
}

is_toolchain_managed_path() {
  local path="$1"
  local root

  root="$(toolchain_user_root)"
  case "${path}" in
  "${root%/}/"*) return 0 ;;
  *) return 1 ;;
  esac
}

publish_tool_command() {
  local index="$1"
  local target_path="$2"
  local command_name
  local command_dir
  local link_path
  local existing_target

  if [[ -n "${prefix_root}" ]]; then
    return 0
  fi

  command_name="$(tool_executable "${index}")"
  command_dir="$(user_command_dir)"
  link_path="${command_dir}/${command_name}"
  ensure_directory "${command_dir}"

  if [[ -e "${link_path}" && ! -L "${link_path}" ]]; then
    log_error "Cannot publish '${command_name}' because '${link_path}' already exists and is not a symlink."
    return 1
  fi

  if [[ -L "${link_path}" ]]; then
    existing_target="$(readlink "${link_path}")" || {
      log_error "Cannot inspect existing command link '${link_path}'."
      return 1
    }
    if ! is_toolchain_managed_path "${existing_target}"; then
      log_error "Cannot replace unmanaged command link '${link_path}'."
      return 1
    fi
    if ! rm -f -- "${link_path}"; then
      log_error "Cannot replace existing command link '${link_path}'."
      return 1
    fi
  fi

  log_verbose "Publishing command '${command_name}' at '${link_path}'."
  ln -s "${target_path}" "${link_path}"
}

publish_installer_command() {
  local index="$1"
  local install_dir
  local bin_path
  local target_path

  if [[ -n "${prefix_root}" ]]; then
    return 0
  fi

  install_dir="$(install_directory "${index}")"
  if [[ -z "${installer_bin_paths[index]}" ]]; then
    bin_path="${install_dir}/bin"
  elif [[ "${installer_bin_paths[index]}" == "." ]]; then
    bin_path="${install_dir}"
  else
    bin_path="${install_dir}/${installer_bin_paths[index]}"
  fi

  target_path="${bin_path}/$(tool_executable "${index}")"
  if [[ ! -e "${target_path}" ]]; then
    log_error "Installer for '${tool_ids[index]}' did not create expected command '${target_path}'."
    return 1
  fi

  publish_tool_command "${index}" "${target_path}"
}

remove_published_tool_command() {
  local index="$1"
  local managed_directory="$2"
  local command_name
  local link_path
  local existing_target

  if [[ -n "${prefix_root}" ]]; then
    return 0
  fi

  command_name="$(tool_executable "${index}")"
  link_path="$(user_command_dir)/${command_name}"
  if [[ ! -L "${link_path}" ]]; then
    return 0
  fi

  existing_target="$(readlink "${link_path}")" || {
    log_warning "Could not inspect command link '${link_path}'. Leaving it in place."
    return 0
  }

  case "${existing_target}" in
  "${managed_directory%/}/"*)
    log_verbose "Removing command link '${link_path}'."
    if ! rm -f -- "${link_path}"; then
      log_warning "Could not remove command link '${link_path}'."
    fi
    ;;
  *)
    log_verbose "Leaving command link '${link_path}' because it does not point into '${managed_directory}'."
    ;;
  esac
}

is_windows_interop_path() {
  local command_path="$1"
  case "${command_path}" in
  /mnt/[A-Za-z]/* | *.exe | *.EXE | *.cmd | *.CMD | *.bat | *.BAT) return 0 ;;
  *) return 1 ;;
  esac
}

linux_command_path() {
  local command_name="$1"
  local command_path

  command_path="$(command -v "${command_name}" 2>/dev/null)" || return 1
  if is_windows_interop_path "${command_path}"; then
    log_verbose "Ignoring Windows interop command for '${command_name}': ${command_path}"
    return 1
  fi

  printf '%s' "${command_path}"
}

add_current_path_entry() {
  local path="$1"
  case "${PATH}" in
  "${path}" | "${path}:"*)
    log_verbose "Current process PATH already starts with '${path}'."
    ;;
  *)
    log_verbose "Prepending '${path}' to the current process PATH."
    PATH="${path}:${PATH}"
    export PATH
    ;;
  esac
  hash -r 2>/dev/null || true
}

ensure_profile_path_entry() {
  local path="$1"
  local profile_path="${HOME}/.profile"
  local marker="# coding-agent-toolchain PATH: ${path}"

  if [[ -f "${profile_path}" ]] && grep -Fq "${marker}" "${profile_path}"; then
    log_verbose "User profile already contains PATH marker for '${path}'."
    return
  fi

  log_verbose "Persisting '${path}' in '${profile_path}'."
  {
    printf '\n%s\n' "${marker}"
    printf '%s\n' "case \":\${PATH}:\" in"
    printf '  *":%s:"*) ;;\n' "${path}"
    printf '  *) PATH="%s:%s" ;;\n' "${path}" "\${PATH}"
    printf 'esac\n'
    printf 'export PATH\n'
  } >>"${profile_path}"
}

add_user_path_entry() {
  local path="$1"
  add_current_path_entry "${path}"
  ensure_profile_path_entry "${path}"
}

add_installer_path_entry() {
  local index="$1"
  local mode="$2"
  local path="$3"
  local label="$4"

  if [[ "${mode}" == "persist" ]]; then
    log_verbose "Adding ${label} persistently for '${tool_ids[index]}': ${path}"
    add_user_path_entry "${path}"
  else
    log_verbose "Adding ${label} for current process for '${tool_ids[index]}': ${path}"
    add_current_path_entry "${path}"
  fi
}

add_installer_path_entries() {
  local index="$1"
  local mode="${2:-persist}"
  local install_dir
  local bin_path
  local system_python
  local user_scripts_dir

  if [[ -z "${installer_bin_paths[index]}" ]]; then
    if [[ "${installer_kinds[index]}" == "pip" || "${installer_kinds[index]}" == "python_user" ]]; then
      if [[ -n "${prefix_root}" ]]; then
        bin_path="$(python_tool_bin_dir "${index}")"
      else
        bin_path="$(user_command_dir)"
      fi
      add_installer_path_entry "${index}" "${mode}" "${bin_path}" "installer bin path"

      if [[ -n "${prefix_root}" ]]; then
        return
      fi

      if system_python="$(python_command 2>/dev/null)" &&
        user_scripts_dir="$(python_user_bin_dir "${system_python}" 2>/dev/null)"; then
        add_installer_path_entry "${index}" "${mode}" "${user_scripts_dir}" "Python user scripts path"
      else
        log_verbose "Python user scripts path is unavailable for '${tool_ids[index]}'."
      fi
      return
    elif [[ "${installer_kinds[index]}" == "npm_global" ]]; then
      bin_path="$(npm_command_dir "${index}")"
      add_installer_path_entry "${index}" "${mode}" "${bin_path}" "npm global bin path"
      add_installer_path_entry "${index}" "${mode}" "$(node_bin_dir)" "Node.js bin path"
      return
    elif [[ "${installer_kinds[index]}" == "conda_forge" ]]; then
      bin_path="$(install_directory "${index}")/bin"
    elif [[ "${installer_kinds[index]}" == "direct_binary" || "${installer_kinds[index]}" == "github_release_asset" || \
      "${installer_kinds[index]}" == "uv_tool" || "${installer_kinds[index]}" == "appimage_extract" ]]; then
      bin_path="$(tool_command_dir "${index}")"
    else
      log_verbose "Installer for '${tool_ids[index]}' does not declare an additional bin_path."
      return
    fi
  else
    install_dir="$(install_directory "${index}")"
    if [[ "${installer_bin_paths[index]}" == "." ]]; then
      bin_path="${install_dir}"
    else
      bin_path="${install_dir}/${installer_bin_paths[index]}"
    fi
  fi

  if uses_published_command "${index}"; then
    bin_path="$(user_command_dir)"
  fi

  add_installer_path_entry "${index}" "${mode}" "${bin_path}" "installer bin path"
}

python_tool_bin_dir() {
  local index="$1"
  printf '%s/bin' "$(install_directory "${index}")"
}

download_file() {
  local url="$1"
  local target_path="$2"
  local curl_command_path=""
  local python_command_path=""
  local wget_command_path=""

  if curl_command_path="$(linux_command_path curl 2>/dev/null)"; then
    log_verbose "Running command: curl -fsSL ${url} -o ${target_path}"
    "${curl_command_path}" -fsSL "${url}" -o "${target_path}"
    return
  fi

  if wget_command_path="$(linux_command_path wget 2>/dev/null)"; then
    log_verbose "Running command: wget -qO ${target_path} ${url}"
    "${wget_command_path}" -qO "${target_path}" "${url}"
    return
  fi

  if python_command_path="$(python_command 2>/dev/null)"; then
    log_verbose "Downloading '${url}' to '${target_path}' with Python urllib."
    CAT_DOWNLOAD_URL="${url}" CAT_DOWNLOAD_TARGET="${target_path}" "${python_command_path}" -c \
      'import os, urllib.request; urllib.request.urlretrieve(os.environ["CAT_DOWNLOAD_URL"], os.environ["CAT_DOWNLOAD_TARGET"])'
    return
  fi

  log_error "Downloading '${url}' requires curl, wget, or Python."
  return 1
}

prepare_user_paths() {
  local index="${1:-0}"
  local bin_dir
  local command_dir
  local npm_prefix

  bin_dir="$(tool_binary_dir "${index}")"
  command_dir="$(tool_command_dir "${index}")"
  npm_prefix="$(npm_prefix_dir "${index}")"
  ensure_directory "${bin_dir}"
  ensure_directory "${command_dir}"
  ensure_directory "${npm_prefix}"
  log_verbose "Prepared tool bin directory '${bin_dir}', command directory '${command_dir}', and npm prefix '${npm_prefix}'."
  add_user_path_entry "${command_dir}"
}

github_release_asset_url() {
  local index="$1"
  local owner
  local repo
  local pattern
  local release_url
  local asset_url
  local release_file

  owner="$(require_installer_value "${installer_owners[index]}" "owner" "${tool_ids[index]}")"
  repo="$(require_installer_value "${installer_repos[index]}" "repo" "${tool_ids[index]}")"
  pattern="$(require_installer_value "${installer_asset_patterns[index]}" "asset_pattern" "${tool_ids[index]}")"
  release_url="https://api.github.com/repos/${owner}/${repo}/releases/latest"
  log_verbose "Fetching latest GitHub release metadata from '${release_url}'."

  release_file="$(mktemp)" || return 1
  if ! download_file "${release_url}" "${release_file}"; then
    rm -f -- "${release_file}"
    return 1
  fi

  asset_url="$(
    awk -v pattern="${pattern}" '
        /"name":/ {
          name = $0
          sub(/^.*"name": "/, "", name)
          sub(/".*$/, "", name)
        }
        /"browser_download_url":/ {
          url = $0
          sub(/^.*"browser_download_url": "/, "", url)
          sub(/".*$/, "", url)
          if (name ~ pattern) {
            print url
            exit
          }
        }
      ' "${release_file}"
  )"
  rm -f -- "${release_file}"

  if [[ -z "${asset_url}" ]]; then
    log_error "Latest GitHub release for '${owner}/${repo}' has no asset matching '${pattern}'."
    return 1
  fi

  log_verbose "Matched GitHub release asset URL for '${tool_ids[index]}': ${asset_url}"
  printf '%s' "${asset_url}"
}

extract_tar_xz() {
  local archive_path="$1"
  local target_dir="$2"
  local python_command_path=""

  if command -v xz >/dev/null 2>&1; then
    log_verbose "Running command: tar -xJf ${archive_path} -C ${target_dir}"
    tar -xJf "${archive_path}" -C "${target_dir}"
    return
  fi

  if ! python_command_path="$(python_command 2>/dev/null)"; then
    log_error "Extracting '${archive_path}' requires xz or Python with lzma support."
    return 1
  fi

  log_verbose "Extracting '${archive_path}' to '${target_dir}' with Python tarfile."
  CAT_ARCHIVE_PATH="${archive_path}" CAT_TARGET_DIR="${target_dir}" "${python_command_path}" -c '
import os
import tarfile

archive_path = os.environ["CAT_ARCHIVE_PATH"]
target_dir = os.path.abspath(os.environ["CAT_TARGET_DIR"])

with tarfile.open(archive_path, "r:xz") as archive:
    for member in archive.getmembers():
        member_path = os.path.abspath(os.path.join(target_dir, member.name))
        if member_path != target_dir and not member_path.startswith(target_dir + os.sep):
            raise RuntimeError(f"Unsafe archive member: {member.name}")
    try:
        archive.extractall(target_dir, filter="data")
    except TypeError:
        archive.extractall(target_dir)
'
}

extract_tar_bz2() {
  local archive_path="$1"
  local target_dir="$2"
  local python_command_path=""

  if command -v bzip2 >/dev/null 2>&1; then
    log_verbose "Running command: tar -xjf ${archive_path} -C ${target_dir}"
    tar -xjf "${archive_path}" -C "${target_dir}"
    return
  fi

  if ! python_command_path="$(python_command 2>/dev/null)"; then
    log_error "Extracting '${archive_path}' requires bzip2 or Python with bz2 support."
    return 1
  fi

  log_verbose "Extracting '${archive_path}' to '${target_dir}' with Python tarfile."
  CAT_ARCHIVE_PATH="${archive_path}" CAT_TARGET_DIR="${target_dir}" "${python_command_path}" -c '
import os
import tarfile

archive_path = os.environ["CAT_ARCHIVE_PATH"]
target_dir = os.path.abspath(os.environ["CAT_TARGET_DIR"])

with tarfile.open(archive_path, "r:bz2") as archive:
    for member in archive.getmembers():
        member_path = os.path.abspath(os.path.join(target_dir, member.name))
        if member_path != target_dir and not member_path.startswith(target_dir + os.sep):
            raise RuntimeError(f"Unsafe archive member: {member.name}")
    try:
        archive.extractall(target_dir, filter="data")
    except TypeError:
        archive.extractall(target_dir)
'
}

installer_download_url() {
  local index="$1"
  if [[ -n "${installer_urls[index]}" ]]; then
    log_verbose "Using configured download URL for '${tool_ids[index]}': ${installer_urls[index]}"
    printf '%s' "${installer_urls[index]}"
  else
    github_release_asset_url "${index}"
  fi
}

python_command() {
  if command -v python3 >/dev/null 2>&1; then
    log_verbose "Using Python command: $(command -v python3)"
    command -v python3
    return
  fi

  if command -v python >/dev/null 2>&1; then
    log_verbose "Using Python command: $(command -v python)"
    command -v python
    return
  fi

  log_error "Python is required for pip installers, but no python3 or python command is available."
  return 1
}

python_user_bin_dir() {
  local python_command_path="$1"
  local user_base

  log_verbose "Resolving Python user base with '${python_command_path} -m site --user-base'."
  user_base="$("${python_command_path}" -m site --user-base)"
  printf '%s/bin' "${user_base}"
}

ensure_user_site_pip() {
  local python_command_path="$1"
  local temp_dir=""
  local get_pip_path=""

  if "${python_command_path}" -m pip --version >/dev/null 2>&1; then
    log_verbose "Python pip is already available for '${python_command_path}'."
    return
  fi

  temp_dir="$(mktemp -d)" || return 1
  get_pip_path="${temp_dir}/get-pip.py"
  if ! download_file "https://bootstrap.pypa.io/get-pip.py" "${get_pip_path}"; then
    rm -rf -- "${temp_dir}"
    return 1
  fi

  log_info "Bootstrapping pip into the current user's Python site."
  if ! "${python_command_path}" "${get_pip_path}" --user --break-system-packages --no-warn-script-location; then
    rm -rf -- "${temp_dir}"
    return 1
  fi

  rm -rf -- "${temp_dir}"
  if ! "${python_command_path}" -m pip --version >/dev/null 2>&1; then
    log_error "Python pip is still unavailable after user-scoped bootstrap."
    return 1
  fi
}

pip_supports_break_system_packages() {
  local python_command_path="$1"
  "${python_command_path}" -m pip help install 2>/dev/null | grep -Fq -- '--break-system-packages'
}

install_user_pip_package() {
  local python_command_path="$1"
  local package="$2"
  local arguments=(install --user --quiet)

  if pip_supports_break_system_packages "${python_command_path}"; then
    arguments+=(--break-system-packages)
  fi

  arguments+=("${package}")
  "${python_command_path}" -m pip "${arguments[@]}"
}

install_python_user_tool() {
  local index="$1"
  local package
  local system_python
  local install_dir
  local scripts_dir
  local user_scripts_dir
  local venv_created=0
  local venv_python

  package="$(require_installer_value "${installer_packages[index]}" "package" "${tool_ids[index]}")"
  system_python="$(python_command)" || return 1
  install_dir="$(install_directory "${index}")"
  scripts_dir="$(python_tool_bin_dir "${index}")"
  venv_python="${scripts_dir}/python"

  log_info "Installing '${tool_ids[index]}' with pip package '${package}' in a user virtual environment."
  ensure_directory "$(dirname "${install_dir}")"
  if ((verbose)); then
    "${system_python}" -m venv "${install_dir}" && venv_created=1
  elif "${system_python}" -m venv "${install_dir}" >/dev/null 2>&1; then
    venv_created=1
  fi

  if ((venv_created)) && [[ -x "${venv_python}" ]] &&
    "${venv_python}" -m pip --version >/dev/null 2>&1; then
    if [[ -n "${prefix_root}" ]]; then
      add_user_path_entry "${scripts_dir}"
    else
      ensure_directory "$(user_command_dir)"
      add_user_path_entry "$(user_command_dir)"
    fi
    log_verbose "Running command: ${venv_python} -m pip install --quiet ${package}"
    "${venv_python}" -m pip install --quiet "${package}"
    publish_installer_command "${index}" || return 1
    return
  fi

  if [[ -n "${prefix_root}" ]]; then
    rm -rf -- "${install_dir}"
    log_error "Tool '${tool_ids[index]}' requires Python venv support when --prefix is used."
    return 1
  fi

  log_info "Python venv support is unavailable. Falling back to user-site pip installation."
  rm -rf -- "${install_dir}"
  user_scripts_dir="$(python_user_bin_dir "${system_python}")"
  ensure_directory "${user_scripts_dir}"
  add_user_path_entry "${user_scripts_dir}"
  ensure_user_site_pip "${system_python}" || return 1
  log_verbose "Installing '${package}' with user-site pip."
  install_user_pip_package "${system_python}" "${package}"
}

install_pip_tool() {
  local index="$1"
  install_python_user_tool "${index}"
}

node_platform() {
  local machine

  machine="$(uname -m)"
  case "${machine}" in
  x86_64 | amd64) printf 'linux-x64' ;;
  aarch64 | arm64) printf 'linux-arm64' ;;
  *)
    log_error "Unsupported Linux architecture for user-scoped Node.js runtime: ${machine}."
    return 1
    ;;
  esac
}

latest_node_lts_version() {
  local platform="$1"
  local index_file="$2"

  awk -v platform="${platform}" '
    $0 ~ "\"files\"" && $0 ~ "\"" platform "\"" && $0 ~ "\"lts\"" &&
      $0 !~ "\"lts\"[[:space:]]*:[[:space:]]*false" {
        version = $0
        sub(/^.*"version"[[:space:]]*:[[:space:]]*"/, "", version)
        sub(/".*$/, "", version)
        print version
        exit
      }
  ' "${index_file}"
}

usable_linux_node_runtime() {
  local node_command_path
  local npm_command_path

  node_command_path="$(linux_command_path node)" || return 1
  npm_command_path="$(linux_command_path npm)" || return 1
  "${node_command_path}" --version >/dev/null 2>&1 || return 1
  "${npm_command_path}" --version >/dev/null 2>&1 || return 1
}

install_linux_node_runtime() {
  local platform
  local version
  local install_dir
  local node_bin_path
  local temp_dir
  local index_file
  local archive_name
  local download_url
  local download_path
  local source_root

  platform="$(node_platform)" || return 1
  install_dir="$(node_install_directory)"
  node_bin_path="$(node_bin_dir)"

  log_info "Installing Node.js for npm-based tools into '${install_dir}'."
  temp_dir="$(mktemp -d)" || return 1
  index_file="${temp_dir}/index.json"
  if ! download_file "https://nodejs.org/dist/index.json" "${index_file}"; then
    rm -rf -- "${temp_dir}"
    return 1
  fi

  version="$(latest_node_lts_version "${platform}" "${index_file}")"
  if [[ -z "${version}" ]]; then
    log_error "Could not find a Node.js LTS release for '${platform}'."
    rm -rf -- "${temp_dir}"
    return 1
  fi

  archive_name="node-${version}-${platform}.tar.xz"
  download_url="https://nodejs.org/dist/${version}/${archive_name}"
  download_path="${temp_dir}/${archive_name}"
  log_verbose "Selected Node.js ${version} for platform '${platform}'."
  if ! download_file "${download_url}" "${download_path}"; then
    rm -rf -- "${temp_dir}"
    return 1
  fi

  if ! extract_tar_xz "${download_path}" "${temp_dir}"; then
    rm -rf -- "${temp_dir}"
    return 1
  fi

  source_root="${temp_dir}/node-${version}-${platform}"
  if [[ ! -d "${source_root}" ]]; then
    log_error "Node.js archive did not extract to '${source_root}'."
    rm -rf -- "${temp_dir}"
    return 1
  fi

  ensure_directory "$(dirname "${install_dir}")"
  rm -rf -- "${install_dir}"
  ensure_directory "${install_dir}"
  cp -R "${source_root}/." "${install_dir}/"
  add_user_path_entry "${node_bin_path}"
  rm -rf -- "${temp_dir}"

  if ! "${node_bin_path}/node" --version >/dev/null 2>&1 ||
    ! "${node_bin_path}/npm" --version >/dev/null 2>&1; then
    log_error "Node.js runtime is still unavailable after user-scoped installation."
    return 1
  fi
}

micromamba_platform() {
  local machine

  machine="$(uname -m)"
  case "${machine}" in
  x86_64 | amd64) printf 'linux-64' ;;
  aarch64 | arm64) printf 'linux-aarch64' ;;
  *)
    log_error "Unsupported Linux architecture for user-scoped micromamba runtime: ${machine}."
    return 1
    ;;
  esac
}

install_micromamba_runtime() {
  local platform
  local install_dir
  local bin_dir
  local temp_dir
  local archive_path
  local source_path
  local target_path

  platform="$(micromamba_platform)" || return 1
  install_dir="$(micromamba_install_directory)"
  bin_dir="${install_dir}/bin"
  target_path="$(micromamba_bin_path)"

  log_info "Installing micromamba into '${install_dir}'."
  temp_dir="$(mktemp -d)" || return 1
  archive_path="${temp_dir}/micromamba.tar.bz2"
  if ! download_file "https://micro.mamba.pm/api/micromamba/${platform}/latest" "${archive_path}"; then
    rm -rf -- "${temp_dir}"
    return 1
  fi

  if ! extract_tar_bz2 "${archive_path}" "${temp_dir}"; then
    rm -rf -- "${temp_dir}"
    return 1
  fi

  source_path="${temp_dir}/bin/micromamba"
  if [[ ! -x "${source_path}" ]]; then
    log_error "micromamba archive did not contain an executable bin/micromamba."
    rm -rf -- "${temp_dir}"
    return 1
  fi

  ensure_directory "${bin_dir}"
  install -m 0755 "${source_path}" "${target_path}"
  rm -rf -- "${temp_dir}"

  if ! "${target_path}" --version >/dev/null 2>&1; then
    log_error "micromamba is still unavailable after user-scoped installation."
    return 1
  fi
}

ensure_micromamba_runtime() {
  local micromamba_command_path

  micromamba_command_path="$(micromamba_bin_path)"
  if [[ -x "${micromamba_command_path}" ]] &&
    "${micromamba_command_path}" --version >/dev/null 2>&1; then
    printf '%s' "${micromamba_command_path}"
    return
  fi

  install_micromamba_runtime || return 1
  printf '%s' "${micromamba_command_path}"
}

install_npm_global_tool() {
  local index="$1"
  local package
  local node_command_path
  local npm_command_path
  local npm_prefix
  local target_path

  package="$(require_installer_value "${installer_packages[index]}" "package" "${tool_ids[index]}")"
  npm_prefix="$(npm_prefix_dir "${index}")"

  add_current_path_entry "$(node_bin_dir)"

  if ! usable_linux_node_runtime; then
    log_info "Linux node/npm are unavailable. Installing a user-scoped Node.js runtime."
    if ! install_linux_node_runtime; then
      log_error "Tool '${tool_ids[index]}' requires a usable Linux node/npm runtime."
      return 1
    fi
  fi

  node_command_path="$(linux_command_path node)" || return 1
  npm_command_path="$(linux_command_path npm)" || return 1
  log_verbose "Using Linux node command: ${node_command_path}"
  log_verbose "Using Linux npm command: ${npm_command_path}"

  log_info "Installing '${tool_ids[index]}' with npm package '${package}'."
  prepare_user_paths "${index}"
  log_verbose "Running command: npm install --global --prefix ${npm_prefix} --silent --no-audit --no-fund ${package}"
  if ! "${npm_command_path}" install --global --prefix "${npm_prefix}" --silent --no-audit --no-fund "${package}"; then
    log_error "npm failed to install package '${package}' for tool '${tool_ids[index]}'."
    return 1
  fi

  target_path="$(npm_bin_dir "${index}")/$(tool_executable "${index}")"
  if [[ ! -e "${target_path}" ]]; then
    log_error "npm package '${package}' did not create expected command '${target_path}'."
    return 1
  fi
  publish_tool_command "${index}" "${target_path}"
}

install_uv_tool() {
  local index="$1"
  local package
  local bin_dir
  local target_path

  package="$(require_installer_value "${installer_packages[index]}" "package" "${tool_ids[index]}")"
  bin_dir="$(tool_binary_dir "${index}")"
  target_path="${bin_dir}/$(tool_executable "${index}")"

  if ! command -v uv >/dev/null 2>&1; then
    log_error "Tool '${tool_ids[index]}' requires uv, but uv is not available."
    return 1
  fi

  log_info "Installing '${tool_ids[index]}' with uv package '${package}'."
  prepare_user_paths "${index}"
  log_verbose "Running command: UV_TOOL_BIN_DIR=${bin_dir} uv tool install --quiet ${package}"
  UV_TOOL_BIN_DIR="${bin_dir}" uv tool install --quiet "${package}"
  if [[ ! -e "${target_path}" ]]; then
    log_error "uv package '${package}' did not create expected command '${target_path}'."
    return 1
  fi
  publish_tool_command "${index}" "${target_path}"
}

install_powershell_gallery_tool() {
  local index="$1"
  local package

  package="$(require_installer_value "${installer_packages[index]}" "package" "${tool_ids[index]}")"

  if ! command -v pwsh >/dev/null 2>&1; then
    log_error "Tool '${tool_ids[index]}' requires pwsh, but pwsh is not available."
    return 1
  fi

  log_info "Installing '${tool_ids[index]}' from PowerShell Gallery package '${package}'."
  log_verbose "Running command: pwsh -NoProfile -Command Install-Module ..."
  CAT_PACKAGE="${package}" pwsh -NoProfile -Command \
    "Install-Module -Name \$env:CAT_PACKAGE -Scope CurrentUser -Force -AllowClobber -Repository PSGallery"
}

install_winget_tool() {
  local index="$1"
  log_error "Installer kind 'winget' is only supported by the Windows PowerShell script for '${tool_ids[index]}'."
  return 1
}

install_chocolatey_tool() {
  local index="$1"
  log_error "Installer kind 'chocolatey' is only supported by the Windows PowerShell script for '${tool_ids[index]}'."
  return 1
}

install_brew_tool() {
  local index="$1"
  local package

  package="$(require_installer_value "${installer_packages[index]}" "package" "${tool_ids[index]}")"

  if ! command -v brew >/dev/null 2>&1; then
    log_error "Tool '${tool_ids[index]}' requires brew, but brew is not available."
    return 1
  fi

  log_info "Installing '${tool_ids[index]}' with Homebrew package '${package}'."
  log_verbose "Running command: brew install ${package}"
  brew install "${package}"
}

install_conda_forge_tool() {
  local index="$1"
  local package
  local install_dir
  local micromamba_command_path
  local root_prefix
  local action="create"

  package="$(require_installer_value "${installer_packages[index]}" "package" "${tool_ids[index]}")"
  install_dir="$(install_directory "${index}")"
  root_prefix="$(micromamba_root_prefix)"
  micromamba_command_path="$(ensure_micromamba_runtime)" || return 1

  ensure_directory "${root_prefix}"
  ensure_directory "$(dirname "${install_dir}")"
  if [[ -d "${install_dir}/conda-meta" ]]; then
    action="install"
  else
    rm -rf -- "${install_dir}"
  fi

  log_info "Installing '${tool_ids[index]}' with conda-forge package '${package}' into '${install_dir}'."
  log_verbose "Running command: micromamba ${action} --yes --quiet --prefix ${install_dir} --channel conda-forge --override-channels ${package}"
  if ! MAMBA_ROOT_PREFIX="${root_prefix}" "${micromamba_command_path}" "${action}" \
    --yes --quiet --prefix "${install_dir}" --channel conda-forge --override-channels "${package}"; then
    log_error "micromamba failed to install conda-forge package '${package}' for tool '${tool_ids[index]}'."
    return 1
  fi

  publish_installer_command "${index}" || return 1
  add_installer_path_entries "${index}" current
}

extract_downloaded_archive() {
  local index="$1"
  local archive_kind="$2"
  local download_path="$3"
  local target_dir="$4"

  case "${archive_kind}" in
  tar_xz)
    extract_tar_xz "${download_path}" "${target_dir}"
    ;;
  tar_gz)
    log_verbose "Running command: tar -xzf ${download_path} -C ${target_dir}"
    tar -xzf "${download_path}" -C "${target_dir}"
    ;;
  zip)
    if ! command -v unzip >/dev/null 2>&1; then
      log_error "Tool '${tool_ids[index]}' requires unzip for zip archive extraction."
      return 1
    fi
    log_verbose "Running command: unzip -q ${download_path} -d ${target_dir}"
    unzip -q "${download_path}" -d "${target_dir}"
    ;;
  *)
    log_error "Unsupported archive_kind '${archive_kind}' for tool '${tool_ids[index]}'."
    return 1
    ;;
  esac
}

copy_extracted_binary() {
  local temp_dir="$1"
  local archive_path="$2"
  local file_name="$3"
  local target_path="$4"
  local source_path="${temp_dir}/${archive_path}"

  if [[ ! -f "${source_path}" ]]; then
    log_verbose "Configured archive path was not found. Searching extracted files for '${file_name}'."
    source_path="$(find "${temp_dir}" -type f -name "${file_name}" -print -quit)"
  fi

  if [[ -z "${source_path}" || ! -f "${source_path}" ]]; then
    log_error "Archive does not contain '${file_name}'."
    return 1
  fi

  log_verbose "Installing extracted binary from '${source_path}' to '${target_path}'."
  install -m 0755 "${source_path}" "${target_path}"
}

install_direct_binary_tool() {
  local index="$1"
  local url
  local file_name
  local archive_kind
  local archive_path
  local bin_dir
  local target_path
  local temp_dir
  local download_path

  url="$(installer_download_url "${index}")" || return 1
  file_name="${installer_file_names[index]:-$(tool_executable "${index}")}"
  archive_kind="${installer_archive_kinds[index]}"
  archive_path="${installer_archive_paths[index]:-${file_name}}"
  bin_dir="$(tool_binary_dir "${index}")"
  target_path="${bin_dir}/${file_name}"

  log_info "Installing '${tool_ids[index]}' from a direct binary download."
  log_verbose "Target binary path: ${target_path}"
  prepare_user_paths "${index}"
  temp_dir="$(mktemp -d)" || return 1
  log_verbose "Created temporary directory '${temp_dir}'."

  if [[ -z "${archive_kind}" ]]; then
    download_path="${temp_dir}/${file_name}"
    if ! download_file "${url}" "${download_path}"; then
      rm -rf -- "${temp_dir}"
      return 1
    fi
    log_verbose "Running command: install -m 0755 ${download_path} ${target_path}"
    if ! install -m 0755 "${download_path}" "${target_path}"; then
      rm -rf -- "${temp_dir}"
      return 1
    fi
  else
    download_path="${temp_dir}/download"
    if ! download_file "${url}" "${download_path}"; then
      rm -rf -- "${temp_dir}"
      return 1
    fi
    if ! extract_downloaded_archive "${index}" "${archive_kind}" "${download_path}" "${temp_dir}"; then
      rm -rf -- "${temp_dir}"
      return 1
    fi

    if ! copy_extracted_binary "${temp_dir}" "${archive_path}" "${file_name}" "${target_path}"; then
      rm -rf -- "${temp_dir}"
      return 1
    fi
  fi

  if ! publish_tool_command "${index}" "${target_path}"; then
    rm -rf -- "${temp_dir}"
    return 1
  fi

  log_verbose "Removing temporary directory '${temp_dir}'."
  rm -rf -- "${temp_dir}"
}

install_portable_archive_tool() {
  local index="$1"
  local url
  local archive_kind
  local archive_path
  local executable
  local install_dir
  local temp_dir
  local download_path
  local extract_dir
  local source_root
  local expected_path
  local has_archive_path=0

  url="$(installer_download_url "${index}")" || return 1
  archive_kind="$(require_installer_value "${installer_archive_kinds[index]}" "archive_kind" "${tool_ids[index]}")" ||
    return 1
  executable="$(tool_executable "${index}")"
  archive_path="${installer_archive_paths[index]:-${executable}}"
  install_dir="$(install_directory "${index}")"

  log_info "Installing '${tool_ids[index]}' from a portable archive."
  temp_dir="$(mktemp -d)" || return 1
  download_path="${temp_dir}/download"
  extract_dir="${temp_dir}/extract"
  ensure_directory "${extract_dir}"

  if ! download_file "${url}" "${download_path}"; then
    rm -rf -- "${temp_dir}"
    return 1
  fi

  if ! extract_downloaded_archive "${index}" "${archive_kind}" "${download_path}" "${extract_dir}"; then
    rm -rf -- "${temp_dir}"
    return 1
  fi

  source_root="${extract_dir}"
  if [[ -n "${installer_archive_paths[index]}" ]]; then
    has_archive_path=1
  fi
  expected_path="${extract_dir}/${archive_path}"

  if [[ ! -f "${expected_path}" ]]; then
    log_verbose "Configured archive path was not found. Searching extracted files for '${executable}'."
    expected_path="$(find "${extract_dir}" -type f -name "${executable}" -print -quit)"
    if [[ -z "${expected_path}" || ! -f "${expected_path}" ]]; then
      log_error "Portable archive for '${tool_ids[index]}' does not contain '${executable}'."
      rm -rf -- "${temp_dir}"
      return 1
    fi

    if ((has_archive_path == 0)); then
      source_root="$(dirname -- "${expected_path}")"
    fi
  fi

  ensure_directory "${install_dir}"
  log_verbose "Copying portable archive contents from '${source_root}' to '${install_dir}'."
  if ! cp -R "${source_root}/." "${install_dir}/"; then
    rm -rf -- "${temp_dir}"
    return 1
  fi
  add_installer_path_entries "${index}"

  log_verbose "Removing temporary directory '${temp_dir}'."
  rm -rf -- "${temp_dir}"
}

install_appimage_extract_tool() {
  local index="$1"
  local url
  local file_name
  local bin_dir
  local target_path
  local install_dir
  local temp_dir
  local appimage_path
  local extracted_root
  local app_run

  url="$(installer_download_url "${index}")" || return 1
  file_name="${installer_file_names[index]:-$(tool_executable "${index}")}"
  bin_dir="$(tool_binary_dir "${index}")"
  target_path="${bin_dir}/${file_name}"
  install_dir="$(install_directory "${index}")"

  log_info "Installing '${tool_ids[index]}' from an extracted AppImage."
  prepare_user_paths "${index}"
  temp_dir="$(mktemp -d)" || return 1
  appimage_path="${temp_dir}/tool.AppImage"
  if ! download_file "${url}" "${appimage_path}"; then
    rm -rf -- "${temp_dir}"
    return 1
  fi

  chmod 0755 "${appimage_path}"
  log_verbose "Running command: ${appimage_path} --appimage-extract"
  if ! (cd "${temp_dir}" && "${appimage_path}" --appimage-extract >/dev/null); then
    rm -rf -- "${temp_dir}"
    return 1
  fi

  extracted_root="${temp_dir}/squashfs-root"
  if [[ ! -d "${extracted_root}" ]]; then
    log_error "AppImage for '${tool_ids[index]}' did not extract to squashfs-root."
    rm -rf -- "${temp_dir}"
    return 1
  fi

  ensure_directory "${install_dir}"
  rm -rf -- "${install_dir}/squashfs-root"
  cp -R "${extracted_root}" "${install_dir}/"
  app_run="${install_dir}/squashfs-root/AppRun"
  if [[ ! -x "${app_run}" ]]; then
    log_error "Extracted AppImage for '${tool_ids[index]}' does not contain an executable AppRun."
    rm -rf -- "${temp_dir}"
    return 1
  fi

  log_verbose "Creating AppImage wrapper '${target_path}'."
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'APPDIR="%s" exec "%s" "$@"\n' "${install_dir}/squashfs-root" "${app_run}"
  } >"${target_path}"
  chmod 0755 "${target_path}"
  if ! publish_tool_command "${index}" "${target_path}"; then
    rm -rf -- "${temp_dir}"
    return 1
  fi
  rm -rf -- "${temp_dir}"
}

installer_is_appimage_download() {
  local index="$1"
  case "${installer_urls[index]} ${installer_asset_patterns[index]} ${installer_file_names[index]}" in
  *AppImage* | *appimage*) return 0 ;;
  *) return 1 ;;
  esac
}

c_compiler_command() {
  local candidate

  for candidate in cc gcc clang; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      printf '%s' "${candidate}"
      return
    fi
  done

  return 1
}

install_source_make_tool() {
  local index="$1"
  local url
  local install_dir
  local source_dir
  local source_root
  local temp_dir
  local download_path
  local compiler
  local make_jobs=1

  url="$(installer_download_url "${index}")" || return 1
  install_dir="$(install_directory "${index}")"
  source_dir="$(require_installer_value "${installer_source_dirs[index]}" "source_dir" "${tool_ids[index]}")" ||
    return 1

  if ! command -v make >/dev/null 2>&1; then
    log_error "Tool '${tool_ids[index]}' requires make to build from source."
    return 1
  fi

  if ! compiler="$(c_compiler_command)"; then
    log_error "Tool '${tool_ids[index]}' requires a C compiler, but cc, gcc, and clang are unavailable."
    return 1
  fi
  log_verbose "Using C compiler command '${compiler}'."

  if command -v nproc >/dev/null 2>&1; then
    make_jobs="$(nproc)"
  fi

  log_info "Installing '${tool_ids[index]}' from source into '${install_dir}'."
  temp_dir="$(mktemp -d)" || return 1
  log_verbose "Created temporary directory '${temp_dir}'."
  download_path="${temp_dir}/source.tar.xz"
  if ! download_file "${url}" "${download_path}"; then
    rm -rf -- "${temp_dir}"
    return 1
  fi
  if ! extract_tar_xz "${download_path}" "${temp_dir}"; then
    rm -rf -- "${temp_dir}"
    return 1
  fi
  log_verbose "Searching source directory '${source_dir}' inside '${temp_dir}'."
  source_root="$(find "${temp_dir}" -maxdepth 1 -type d -name "${source_dir}" -print -quit)"

  if [[ -z "${source_root}" ]]; then
    log_error "Source archive for '${tool_ids[index]}' does not contain '${source_dir}'."
    rm -rf -- "${temp_dir}"
    return 1
  fi

  ensure_directory "${install_dir}"
  log_verbose "Running source build from '${source_root}' with ${make_jobs} make job(s)."
  if ! (
    cd "${source_root}"
    log_verbose "Running command: ./configure --prefix=${install_dir}"
    ./configure --prefix="${install_dir}"
    log_verbose "Running command: make -j ${make_jobs}"
    make -j "${make_jobs}"
    log_verbose "Running command: make install"
    make install
  ); then
    rm -rf -- "${temp_dir}"
    return 1
  fi

  if ! publish_installer_command "${index}"; then
    rm -rf -- "${temp_dir}"
    return 1
  fi
  add_installer_path_entries "${index}" current
  log_verbose "Removing temporary directory '${temp_dir}'."
  rm -rf -- "${temp_dir}"
}

install_source_make_with_fallback_tool() {
  local index="$1"

  if [[ "${tool_ids[index]}" == "ghostscript" ]] && ! c_compiler_command >/dev/null 2>&1; then
    log_info "No C compiler found for Ghostscript. Falling back to the user-scoped conda-forge installer."
    install_conda_forge_tool "${index}"
    return
  fi

  install_source_make_tool "${index}"
}

install_tool() {
  local index="$1"

  log_verbose "Dispatching installer kind '${installer_kinds[index]}' for tool '${tool_ids[index]}'."
  case "${installer_kinds[index]}" in
  npm_global) install_npm_global_tool "${index}" ;;
  uv_tool) install_uv_tool "${index}" ;;
  pip) install_pip_tool "${index}" ;;
  python_user) install_python_user_tool "${index}" ;;
  powershell_gallery) install_powershell_gallery_tool "${index}" ;;
  brew) install_brew_tool "${index}" ;;
  conda_forge) install_conda_forge_tool "${index}" ;;
  winget) install_winget_tool "${index}" ;;
  chocolatey) install_chocolatey_tool "${index}" ;;
  direct_binary | github_release_asset)
    if installer_is_appimage_download "${index}"; then
      log_verbose "Installer for '${tool_ids[index]}' points to an AppImage; extracting it instead of installing it directly."
      install_appimage_extract_tool "${index}"
    else
      install_direct_binary_tool "${index}"
    fi
    ;;
  portable_archive) install_portable_archive_tool "${index}" ;;
  appimage_extract) install_appimage_extract_tool "${index}" ;;
  source_make) install_source_make_with_fallback_tool "${index}" ;;
  *)
    log_error "Unsupported installer kind '${installer_kinds[index]}' for tool '${tool_ids[index]}'."
    return 1
    ;;
  esac
}

is_powershell_module_available() {
  local package="$1"
  log_verbose "Checking PowerShell module availability for '${package}'."
  command -v pwsh >/dev/null 2>&1 || return 1
  CAT_PACKAGE="${package}" pwsh -NoProfile -Command \
    "\$module = Get-Module -ListAvailable -Name \$env:CAT_PACKAGE | Sort-Object Version -Descending | Select-Object -First 1; if (\$null -eq \$module) { exit 1 }"
}

is_tool_available() {
  local index="$1"
  local executable
  local executable_path

  if [[ "${installer_kinds[index]}" == "powershell_gallery" ]]; then
    local package
    package="$(require_installer_value "${installer_packages[index]}" "package" "${tool_ids[index]}")"
    is_powershell_module_available "${package}"
    return
  fi

  add_installer_path_entries "${index}" current
  executable="$(tool_executable "${index}")"
  log_verbose "Checking executable availability for '${tool_ids[index]}': ${executable}"
  executable_path="$(linux_command_path "${executable}")" || return 1
  log_verbose "Resolved executable for '${tool_ids[index]}': ${executable_path}"
}

get_powershell_module_version() {
  local package="$1"
  CAT_PACKAGE="${package}" pwsh -NoProfile -Command \
    "\$module = Get-Module -ListAvailable -Name \$env:CAT_PACKAGE | Sort-Object Version -Descending | Select-Object -First 1; if (\$null -eq \$module) { exit 1 }; \$module.Version.ToString()"
}

get_tool_version() {
  local index="$1"
  local executable
  local executable_name
  local version_output

  if [[ "${installer_kinds[index]}" == "powershell_gallery" ]]; then
    local package
    package="$(require_installer_value "${installer_packages[index]}" "package" "${tool_ids[index]}")"
    get_powershell_module_version "${package}"
    return
  fi

  if [[ "${tool_version_checks[index]}" == "command_available" ]]; then
    printf 'available\n'
    return
  fi

  add_installer_path_entries "${index}"
  executable_name="$(tool_executable "${index}")"
  executable="$(linux_command_path "${executable_name}")" || {
    log_error "Executable '${executable_name}' is not available as a Linux command."
    return 1
  }
  log_verbose "Running version command for '${tool_ids[index]}': ${executable} ${tool_version_args[index]}"

  if [[ -z "${tool_version_args[index]}" ]]; then
    if ! version_output="$("${executable}" 2>&1)"; then
      printf '%s\n' "${version_output}" >&2
      return 1
    fi
    version_output="${version_output//$'\n'/ }"
    printf '%s\n' "${version_output}"
    return
  fi

  local args=()
  local old_ifs="${IFS}"
  IFS="${arg_delimiter}"
  read -r -a args <<<"${tool_version_args[index]}"
  IFS="${old_ifs}"

  if ! version_output="$("${executable}" "${args[@]}" 2>&1)"; then
    printf '%s\n' "${version_output}" >&2
    return 1
  fi
  version_output="${version_output//$'\n'/ }"
  printf '%s\n' "${version_output}"
}

get_tool_directory() {
  local index="$1"
  local executable
  local executable_name
  local directory

  if [[ "${installer_kinds[index]}" == "powershell_gallery" ]]; then
    local package
    package="$(require_installer_value "${installer_packages[index]}" "package" "${tool_ids[index]}")"
    CAT_PACKAGE="${package}" pwsh -NoProfile -Command \
      "\$module = Get-Module -ListAvailable -Name \$env:CAT_PACKAGE | Sort-Object Version -Descending | Select-Object -First 1; if (\$null -eq \$module) { exit 1 }; \$module.ModuleBase"
    return
  fi

  add_installer_path_entries "${index}" current
  executable_name="$(tool_executable "${index}")"
  executable="$(linux_command_path "${executable_name}")" || return 1
  directory="$(dirname -- "${executable}")"
  case "${directory}" in
  */) printf '%s' "${directory}" ;;
  *) printf '%s/' "${directory}" ;;
  esac
}

summary_version() {
  local value="$1"

  if ((${#value} > 64)); then
    printf '%s...' "${value:0:61}"
  else
    printf '%s' "${value}"
  fi
}

summary_directory() {
  local value="$1"

  if ((${#value} > 64)); then
    printf '%s...' "${value:0:61}"
  else
    printf '%s' "${value}"
  fi
}

path_contains_directory() {
  local directory="${1%/}"
  local entry
  local entries=()
  local old_ifs="${IFS}"

  IFS=':'
  read -r -a entries <<<"${PATH}"
  IFS="${old_ifs}"

  for entry in "${entries[@]}"; do
    entry="${entry%/}"
    if [[ -n "${entry}" && "${entry}" == "${directory}" ]]; then
      return 0
    fi
  done

  return 1
}

persistent_user_path_entries() {
  local profile_path="${HOME}/.profile"
  local marker_prefix="# coding-agent-toolchain PATH: "
  local line

  [[ -f "${profile_path}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    case "${line}" in
    "${marker_prefix}"*) printf '%s\n' "${line#"${marker_prefix}"}" ;;
    esac
  done <"${profile_path}"
}

normalize_path_text() {
  local path="$1"

  while [[ "${path}" != "/" && "${path}" == */ ]]; do
    path="${path%/}"
  done

  printf '%s' "${path}"
}

path_entry_references_directory() {
  local entry
  local directory

  entry="$(normalize_path_text "$1")"
  directory="$(normalize_path_text "$2")"
  [[ -n "${entry}" && -n "${directory}" ]] || return 1
  [[ "${entry}" == "${directory}" || "${entry}" == "${directory}/"* ]]
}

path_verification_status() {
  local status="$1"
  local directory="$2"

  if [[ "${status}" == "DryRun" ]]; then
    printf 'Simulated'
  elif [[ "${status}" == "Skipped" ]]; then
    printf 'Skipped'
  elif [[ -z "${directory}" ]]; then
    printf 'NotResolved'
  elif path_contains_directory "${directory}"; then
    printf 'InPath'
  else
    printf 'Missing'
  fi
}

ensure_remove_mode_allowed() {
  if [[ -z "${HOME:-}" || ! -d "${HOME}" ]]; then
    log_error "--remove requires a valid current user's HOME directory."
    return 2
  fi
}

format_directory() {
  local directory="$1"

  if [[ -z "${directory}" ]]; then
    return
  fi

  case "${directory}" in
  */) printf '%s' "${directory}" ;;
  *) printf '%s/' "${directory}" ;;
  esac
}

physical_directory() {
  local directory="$1"

  (cd "${directory}" && pwd -P)
}

same_existing_directory() {
  local left="$1"
  local right="$2"
  local left_physical
  local right_physical

  [[ -d "${left}" && -d "${right}" ]] || return 1
  left_physical="$(physical_directory "${left}")" || return 1
  right_physical="$(physical_directory "${right}")" || return 1
  [[ "${left_physical}" == "${right_physical}" ]]
}

is_shared_removal_directory() {
  local directory="$1"
  local candidate
  local shared_directories=(
    "${HOME}/.local"
    "$(user_command_dir)"
    "$(toolchain_user_root)"
    "$(toolchain_user_root)/tools"
    "$(toolchain_payload_root)"
    "$(toolchain_payload_root)/bin"
    "$(node_install_directory)"
    "$(micromamba_install_directory)"
    "$(micromamba_root_prefix)"
  )

  for candidate in "${shared_directories[@]}"; do
    if same_existing_directory "${directory}" "${candidate}"; then
      return 0
    fi
  done

  return 1
}

validate_removal_directory() {
  local directory="$1"
  local target
  local home_physical
  local toolchain_root
  local toolchain_root_physical
  local is_user_scoped=0
  local marker_path

  if [[ -z "${directory}" ]]; then
    printf 'No managed installation directory could be resolved.'
    return 1
  fi

  if [[ ! -d "${directory}" ]]; then
    printf 'Managed installation directory does not exist.'
    return 1
  fi

  target="$(physical_directory "${directory}")" || {
    printf 'Managed installation directory could not be resolved.'
    return 1
  }
  home_physical="$(physical_directory "${HOME}")" || {
    printf 'Current user HOME could not be resolved.'
    return 1
  }

  case "${target}/" in
  "${home_physical}/"*) is_user_scoped=1 ;;
  esac

  toolchain_root="$(toolchain_user_root)"
  if [[ -d "${toolchain_root}" ]]; then
    toolchain_root_physical="$(physical_directory "${toolchain_root}")" || {
      printf 'Toolchain data root could not be resolved.'
      return 1
    }
    case "${target}/" in
    "${toolchain_root_physical}/"*) is_user_scoped=1 ;;
    esac
  fi

  if ((is_user_scoped == 0)); then
    printf 'Managed installation directory is outside the current user HOME and toolchain data root.'
    return 1
  fi

  if [[ "${target}" == "${home_physical}" ]]; then
    printf 'Refusing to remove the current user HOME directory.'
    return 1
  fi

  if is_shared_removal_directory "${target}"; then
    printf 'Managed installation directory is shared; removal is unsafe.'
    return 1
  fi

  marker_path="${target}/.coding-agent-toolchain"
  if [[ ! -f "${marker_path}" ]]; then
    printf 'Installation marker is missing; removal skipped.'
    return 1
  fi

  printf '%s' "${target}"
}

removal_display_directory() {
  local index="$1"
  local directory
  local marker_directory

  if directory="$(get_tool_directory "${index}" 2>/dev/null)"; then
    printf '%s' "${directory}"
    return
  fi

  marker_directory="$(install_marker_directory "${index}" "")"
  format_directory "${marker_directory}"
}

removal_version() {
  local index="$1"
  local version

  if is_tool_available "${index}" && version="$(get_tool_version "${index}" 2>/dev/null)"; then
    printf '%s' "${version}"
  fi
}

run_remove_mode() {
  ensure_remove_mode_allowed || return $?

  if ((dry_run)); then
    log_info "Dry-run remove mode enabled. No files or directories will be removed."
  else
    log_info "Remove mode enabled. Only marked user-scoped tool directories can be removed."
  fi

  local statuses=()
  local versions=()
  local directories=()
  local removed_directories=()
  local details=()
  local index
  local tool_count="${#tool_ids[@]}"
  local display_directory
  local marker_directory
  local validated_directory
  local has_failure=0
  local display_value
  local obsolete_path_entries=()

  for index in "${!tool_ids[@]}"; do
    statuses[index]="Skipped"
    versions[index]=""
    directories[index]=""
    removed_directories[index]=""
    details[index]=""

    log_info "[$((index + 1))/${tool_count}] Checking removal for tool '${tool_ids[index]}'."

    if ! is_tool_supported_on_platform "${index}"; then
      details[index]="$(unsupported_tool_detail "${index}")"
      log_warning "${details[index]}"
      continue
    fi

    if ((dry_run)); then
      statuses[index]="DryRun"
      versions[index]="simulated"
      directories[index]="simulated"
      details[index]="Dry-run: simulated successful removal without modifications."
      continue
    fi

    display_directory="$(removal_display_directory "${index}")"
    directories[index]="${display_directory}"
    versions[index]="$(removal_version "${index}")"
    marker_directory="$(install_marker_directory "${index}" "${display_directory}")"

    if ! validated_directory="$(validate_removal_directory "${marker_directory}")"; then
      details[index]="${validated_directory}"
      log_warning "Tool '${tool_ids[index]}' was not removed: ${details[index]}"
      continue
    fi

    if [[ -z "${directories[index]}" ]]; then
      directories[index]="$(format_directory "${validated_directory}")"
    fi

    log_info "Removing tool '${tool_ids[index]}' directory: ${validated_directory}"
    if ! rm -rf -- "${validated_directory}"; then
      statuses[index]="Failed"
      details[index]="Removal failed."
      has_failure=1
      continue
    fi

    if [[ -e "${validated_directory}" ]]; then
      statuses[index]="Failed"
      details[index]="Managed installation directory still exists after removal."
      has_failure=1
      continue
    fi

    removed_directories[index]="${validated_directory}"
    remove_published_tool_command "${index}" "${validated_directory}"
    statuses[index]="Removed"
  done

  printf '\nTool removal summary:\n'
  printf '%-22s %-10s %-64s %s\n' 'Tool' 'Status' 'Directory' 'Version'
  printf '%-22s %-10s %-64s %s\n' '----' '------' '---------' '-------'

  for index in "${!tool_ids[@]}"; do
    display_value="${versions[index]}"
    if [[ ("${statuses[index]}" == "Failed" || "${statuses[index]}" == "Skipped") && -n "${details[index]}" ]]; then
      display_value="${details[index]}"
    fi

    printf '%-22s %-10s %-64s %s\n' \
      "${tool_ids[index]}" \
      "${statuses[index]}" \
      "$(summary_directory "${directories[index]}")" \
      "$(summary_version "${display_value}")"
  done

  for index in "${!tool_ids[@]}"; do
    [[ "${statuses[index]}" == "Removed" && -n "${removed_directories[index]}" ]] || continue

    while IFS= read -r path_entry; do
      if ! path_entry_references_directory "${path_entry}" "${removed_directories[index]}"; then
        continue
      fi

      local already_listed=0
      local existing_path_entry
      for existing_path_entry in "${obsolete_path_entries[@]}"; do
        if [[ "${existing_path_entry}" == "${path_entry}" ]]; then
          already_listed=1
          break
        fi
      done

      if ((already_listed == 0)); then
        obsolete_path_entries+=("${path_entry}")
      fi
    done < <(persistent_user_path_entries)
  done

  if ((${#obsolete_path_entries[@]} > 0)); then
    printf '\nObsolete PATH entries still present in the user profile:\n'
    for display_value in "${obsolete_path_entries[@]}"; do
      printf '  %s\n' "${display_value}"
    done
    has_failure=1
  fi

  return "${has_failure}"
}

validate_prefix_root() {
  local home_physical
  local prefix_physical

  if [[ -z "${prefix_root}" ]]; then
    return 0
  fi

  if [[ -z "${HOME:-}" || ! -d "${HOME}" ]]; then
    log_error "--prefix requires a valid current user's HOME directory."
    return 2
  fi

  if [[ "${prefix_root}" != /* ]]; then
    prefix_root="$(normalize_prefix_root "$(pwd -P)/${prefix_root}")"
  fi

  if [[ ! -d "${prefix_root}" ]]; then
    log_error "--prefix must point to an existing directory inside the current user's HOME."
    return 2
  fi

  prefix_physical="$(physical_directory "${prefix_root}")" || {
    log_error "--prefix directory could not be resolved."
    return 2
  }
  home_physical="$(physical_directory "${HOME}")" || {
    log_error "--prefix requires a valid current user's HOME directory."
    return 2
  }

  prefix_root="$(normalize_prefix_root "${prefix_physical}")"
  home_physical="$(normalize_prefix_root "${home_physical}")"

  if [[ "${prefix_root}" == "${home_physical}" || "${prefix_root}" == "${home_physical}/"* ]]; then
    return 0
  fi

  log_error "--prefix must point inside the current user's HOME to preserve user-scoped installation."
  return 2
}

validate_xdg_data_home() {
  local home_physical
  local xdg_physical

  if [[ -z "${XDG_DATA_HOME:-}" || "${XDG_DATA_HOME}" != /* ]]; then
    return 0
  fi

  if [[ -z "${HOME:-}" || ! -d "${HOME}" ]]; then
    log_error "XDG_DATA_HOME requires a valid current user's HOME directory."
    return 2
  fi

  home_physical="$(physical_directory "${HOME}")" || {
    log_error "XDG_DATA_HOME requires a valid current user's HOME directory."
    return 2
  }
  home_physical="$(normalize_absolute_path_text "${home_physical}")"
  xdg_physical="$(resolve_directory_path_candidate "${XDG_DATA_HOME}")" || {
    log_error "XDG_DATA_HOME must be a resolvable user-scoped data root."
    return 2
  }
  xdg_physical="$(normalize_absolute_path_text "${xdg_physical}")"

  if [[ "${xdg_physical}" == "${home_physical}" ||
    "${xdg_physical}" == "${home_physical}/"* ]]; then
    return 0
  fi

  log_error \
    "XDG_DATA_HOME must point inside the current user's HOME to preserve user-scoped installation."
  return 2
}

main() {
  while (($# > 0)); do
    case "$1" in
    -c | --config)
      if (($# < 2)); then
        log_error "$1 requires a path."
        usage >&2
        return 2
      fi
      config_path="$2"
      shift 2
      ;;
    -v | --verbose)
      verbose=1
      shift
      ;;
    -d | --dry-run)
      dry_run=1
      shift
      ;;
    -r | --remove)
      remove_mode=1
      shift
      ;;
    --check-path)
      check_path=1
      shift
      ;;
    -p | --prefix)
      if (($# < 2)); then
        log_error "$1 requires a path."
        usage >&2
        return 2
      fi
      prefix_root="$(normalize_prefix_root "$2")"
      shift 2
      ;;
    -h | --help)
      help_requested=1
      shift
      ;;
    *)
      log_error "Unknown option: $1"
      usage >&2
      return 2
      ;;
    esac
  done

  ensure_public_mode_allowed || return $?

  if ((help_requested)); then
    usage
    return 0
  fi

  validate_prefix_root || return $?
  validate_xdg_data_home || return $?

  log_info "Starting Coding Agent Toolchain for Linux."
  log_info "Using configuration: ${config_path}"
  if [[ -n "${prefix_root}" ]]; then
    log_info "Using installation root: $(toolchain_user_root)"
  fi
  log_verbose "User root: $(toolchain_user_root)"
  log_verbose "Payload root: $(toolchain_payload_root)"
  read_manifest "${config_path}"
  log_info "Loaded ${#tool_ids[@]} tool entries from the manifest."
  if ((remove_mode)); then
    run_remove_mode
    return $?
  fi

  if ((dry_run)); then
    log_info "Dry-run mode enabled. No commands, downloads, PATH changes, or installations will be executed."
  fi

  local statuses=()
  local versions=()
  local directories=()
  local details=()
  local index
  local directory
  local tool_count="${#tool_ids[@]}"

  for index in "${!tool_ids[@]}"; do
    statuses[index]="Present"
    versions[index]=""
    directories[index]=""
    details[index]=""
    local needs_install=0

    log_info "[$((index + 1))/${tool_count}] Checking tool '${tool_ids[index]}'."
    log_verbose "Installer kind for '${tool_ids[index]}': ${installer_kinds[index]}"

    if ! is_tool_supported_on_platform "${index}"; then
      statuses[index]="Skipped"
      details[index]="$(unsupported_tool_detail "${index}")"
      log_warning "${details[index]}"
      continue
    fi

    if ((dry_run)); then
      dry_run_tool "${index}"
      statuses[index]="DryRun"
      versions[index]="simulated"
      directories[index]="simulated"
      details[index]="Dry-run: simulated successful execution without modifications."
      continue
    fi

    if details[index]="$(missing_prerequisite_detail "${index}")"; then
      statuses[index]="Skipped"
      log_warning "${details[index]}"
      continue
    fi
    details[index]=""

    if is_tool_available "${index}"; then
      if directory="$(get_tool_directory "${index}" 2>/dev/null)"; then
        directories[index]="${directory}"
      fi
      log_info "Tool '${tool_ids[index]}' is available. Checking version."
      if ! versions[index]="$(get_tool_version "${index}")"; then
        needs_install=1
        details[index]="Existing version check failed."
        versions[index]=""
        log_error "${details[index]}"
      else
        log_info "Tool '${tool_ids[index]}' version detected: ${versions[index]}"
      fi
    else
      needs_install=1
    fi

    if ((needs_install)); then
      log_info "Tool '${tool_ids[index]}' is not installed. Installing it now."
      statuses[index]="Installed"
      if ! install_tool "${index}"; then
        statuses[index]="Failed"
        details[index]="Installation failed. See console output above."
        continue
      fi
    fi

    log_info "Verifying tool '${tool_ids[index]}' after installation checks."
    if ! is_tool_available "${index}"; then
      statuses[index]="Missing"
      if [[ -z "${details[index]}" ]]; then
        details[index]="Tool is still unavailable after installation."
      fi
      continue
    fi

    if directory="$(get_tool_directory "${index}" 2>/dev/null)"; then
      directories[index]="${directory}"
    fi

    if ! versions[index]="$(get_tool_version "${index}")"; then
      statuses[index]="Failed"
      details[index]="Version command failed."
    else
      details[index]=""
      if [[ "${statuses[index]}" == "Installed" ]] && ! write_install_marker_for_tool "${index}" "${directories[index]}"; then
        statuses[index]="Failed"
        details[index]="Installation marker could not be created."
        continue
      fi
      log_info "Tool '${tool_ids[index]}' final version: ${versions[index]}"
    fi
  done

  if ((check_path)); then
    printf '\nPATH verification:\n'
    printf '%-22s %-10s %s\n' 'Tool' 'Status' 'Directory'
    printf '%-22s %-10s %s\n' '----' '------' '---------'

    for index in "${!tool_ids[@]}"; do
      printf '%-22s %-10s %s\n' \
        "${tool_ids[index]}" \
        "$(path_verification_status "${statuses[index]}" "${directories[index]}")" \
        "${directories[index]}"
    done
  fi

  printf '\nTool installation summary:\n'
  printf '%-22s %-10s %-64s %s\n' 'Tool' 'Status' 'Directory' 'Version'
  printf '%-22s %-10s %-64s %s\n' '----' '------' '---------' '-------'

  local has_failure=0
  local display_value
  for index in "${!tool_ids[@]}"; do
    display_value="${versions[index]}"
    if [[ ("${statuses[index]}" == "Failed" || "${statuses[index]}" == "Missing" || \
      "${statuses[index]}" == "Skipped") && -n "${details[index]}" ]]; then
      display_value="${details[index]}"
    fi

    printf '%-22s %-10s %-64s %s\n' \
      "${tool_ids[index]}" \
      "${statuses[index]}" \
      "$(summary_directory "${directories[index]}")" \
      "$(summary_version "${display_value}")"
    if [[ -n "${details[index]}" && "${display_value}" != "${details[index]}" ]]; then
      printf '  %s\n' "${details[index]}"
    fi

    if [[ "${statuses[index]}" == "Failed" || "${statuses[index]}" == "Missing" ]]; then
      has_failure=1
    fi
  done

  return "${has_failure}"
}

main "$@"

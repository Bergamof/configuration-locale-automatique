#!/usr/bin/env bash
#
# Point d'entrée unique de la configuration automatique du poste.
#
# Installe le strict minimum (git, Ansible, collections), demande le profil
# à appliquer, puis délègue tout le reste au playbook Ansible.
#
# Usage : ./bootstrap.sh [options]

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly PROFILES_DIR="${SCRIPT_DIR}/profiles"
readonly PLAYBOOK="${SCRIPT_DIR}/site.yml"
readonly REQUIREMENTS="${SCRIPT_DIR}/requirements.yml"
readonly VAULT_FILE="${SCRIPT_DIR}/inventory/group_vars/all/vault.yml"
readonly VAULT_PASS_FILE="${SCRIPT_DIR}/.vault_pass"
readonly MIN_ANSIBLE_VERSION="2.15"

# Options, surchargées par la ligne de commande.
PROFILE=""
TAGS=""
SKIP_TAGS=""
CHECK_MODE="false"
VERBOSE=""
ASSUME_YES="false"

# --- Sortie ------------------------------------------------------------------

if [[ -t 1 ]]; then
  readonly C_RESET=$'\033[0m'
  readonly C_BOLD=$'\033[1m'
  readonly C_BLUE=$'\033[34m'
  readonly C_GREEN=$'\033[32m'
  readonly C_YELLOW=$'\033[33m'
  readonly C_RED=$'\033[31m'
else
  readonly C_RESET="" C_BOLD="" C_BLUE="" C_GREEN="" C_YELLOW="" C_RED=""
fi

info() { printf '%s==>%s %s\n' "${C_BLUE}${C_BOLD}" "${C_RESET}" "$*"; }
success() { printf '%s==>%s %s\n' "${C_GREEN}${C_BOLD}" "${C_RESET}" "$*"; }
warn() { printf '%s==>%s %s\n' "${C_YELLOW}${C_BOLD}" "${C_RESET}" "$*" >&2; }
die() {
  printf '%serreur:%s %s\n' "${C_RED}${C_BOLD}" "${C_RESET}" "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
${C_BOLD}Configuration automatique du poste${C_RESET}

Usage : ${0##*/} [options]

Options :
  -p, --profile NOM     Profil à appliquer (sans cette option, un menu
                        interactif propose les profils disponibles).
  -t, --tags LISTE      Ne jouer que ces rôles (liste séparée par des
                        virgules) : base, shell, git, ssh, dev, desktop.
      --skip-tags LISTE Jouer tout sauf ces rôles.
  -c, --check           Simulation : n'applique aucune modification.
  -y, --yes             Ne pas demander de confirmation avant d'appliquer.
  -v, --verbose         Sortie Ansible détaillée (répétable : -vv, -vvv).
  -l, --list            Lister les profils disponibles et quitter.
  -h, --help            Afficher cette aide et quitter.

Exemples :
  ./${0##*/}                            # menu interactif
  ./${0##*/} -p boulot                  # profil professionnel complet
  ./${0##*/} -p perso -t shell,git      # seulement le shell et git
  ./${0##*/} -p perso --check           # simulation, sans rien modifier
EOF
}

# --- Détection du système ----------------------------------------------------

# Renseigne OS_ID, OS_ID_LIKE et OS_NAME à partir de /etc/os-release.
detect_os() {
  [[ -r /etc/os-release ]] || die "/etc/os-release introuvable : système non reconnu."

  # shellcheck disable=SC1091
  . /etc/os-release

  OS_ID="${ID:-}"
  OS_ID_LIKE="${ID_LIKE:-}"
  OS_NAME="${PRETTY_NAME:-${OS_ID}}"

  case " ${OS_ID} ${OS_ID_LIKE} " in
    *" arch "*) OS_FAMILY="arch" ;;
    *" debian "* | *" ubuntu "*) OS_FAMILY="debian" ;;
    *) die "Distribution non prise en charge : ${OS_NAME}. Familles supportées : Arch (Manjaro), Debian (Ubuntu)." ;;
  esac

  readonly OS_ID OS_ID_LIKE OS_NAME OS_FAMILY
}

# --- Installation des prérequis ----------------------------------------------

# Installe une liste de paquets avec le gestionnaire de la distribution.
install_packages() {
  local packages=("$@")
  info "Installation des prérequis : ${packages[*]}"

  case "${OS_FAMILY}" in
    arch)
      sudo pacman -Sy --needed --noconfirm "${packages[@]}"
      ;;
    debian)
      sudo apt-get update -qq
      DEBIAN_FRONTEND=noninteractive sudo -E apt-get install -y --no-install-recommends "${packages[@]}"
      ;;
  esac
}

# Traduit un besoin générique en nom de paquet pour la distribution.
package_name_for() {
  local requirement="$1"

  case "${requirement}:${OS_FAMILY}" in
    ansible:arch) printf 'ansible' ;;
    ansible:debian) printf 'ansible' ;;
    git:*) printf 'git' ;;
    *) die "Prérequis inconnu : ${requirement}" ;;
  esac
}

# Vérifie qu'Ansible est présent et suffisamment récent, l'installe sinon.
ensure_dependencies() {
  local missing=()

  command -v git >/dev/null 2>&1 || missing+=("$(package_name_for git)")
  command -v ansible-playbook >/dev/null 2>&1 || missing+=("$(package_name_for ansible)")

  if ((${#missing[@]} > 0)); then
    install_packages "${missing[@]}"
  else
    info "git et Ansible sont déjà installés."
  fi

  command -v ansible-playbook >/dev/null 2>&1 ||
    die "Ansible reste introuvable après installation."

  check_ansible_version
}

# Compare la version d'ansible-core au minimum requis.
check_ansible_version() {
  local version
  version="$(ansible --version | awk 'NR == 1 { gsub(/[^0-9.]/, "", $NF); print $NF; exit }')"
  [[ -n "${version}" ]] || {
    warn "Version d'Ansible indéterminée, vérification ignorée."
    return 0
  }

  local lowest
  lowest="$(printf '%s\n%s\n' "${version}" "${MIN_ANSIBLE_VERSION}" | sort -V | head -n1)"

  if [[ "${lowest}" != "${MIN_ANSIBLE_VERSION}" ]]; then
    die "Ansible ${version} est trop ancien (minimum ${MIN_ANSIBLE_VERSION}). Mettre à jour la distribution ou installer Ansible via pipx."
  fi

  info "Ansible ${version} détecté."
}

# Installe les collections Ansible nécessaires aux rôles.
install_collections() {
  info "Installation des collections Ansible."
  ansible-galaxy collection install --requirements-file "${REQUIREMENTS}" >/dev/null
}

# --- Profils -----------------------------------------------------------------

# Liste les profils disponibles (tout profiles/*.yml sauf le tronc commun).
list_profiles() {
  local file name
  for file in "${PROFILES_DIR}"/*.yml; do
    [[ -e "${file}" ]] || continue
    name="$(basename "${file}" .yml)"
    if [[ "${name}" == "common" ]]; then
      continue
    fi
    printf '%s\n' "${name}"
  done
}

# Vérifie qu'un profil existe.
validate_profile() {
  local candidate="$1"
  local available
  available="$(list_profiles)"

  if ! printf '%s\n' "${available}" | grep -qx -- "${candidate}"; then
    die "Profil inconnu : ${candidate}. Profils disponibles : $(printf '%s' "${available}" | tr '\n' ' ')"
  fi
}

# Menu interactif de sélection du profil.
select_profile() {
  local -a profiles
  mapfile -t profiles < <(list_profiles)

  ((${#profiles[@]} > 0)) || die "Aucun profil trouvé dans ${PROFILES_DIR}."

  if ((${#profiles[@]} == 1)); then
    PROFILE="${profiles[0]}"
    info "Profil unique disponible : ${PROFILE}"
    return 0
  fi

  printf '\n%sProfil à appliquer :%s\n\n' "${C_BOLD}" "${C_RESET}"

  local index=1 profile
  for profile in "${profiles[@]}"; do
    printf '  %s%d%s) %s\n' "${C_BOLD}" "${index}" "${C_RESET}" "${profile}"
    index=$((index + 1))
  done
  printf '\n'

  local choice
  while true; do
    read -r -p "Votre choix [1-${#profiles[@]}] : " choice
    if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#profiles[@]})); then
      PROFILE="${profiles[choice - 1]}"
      return 0
    fi
    warn "Saisie invalide."
  done
}

# --- Exécution ---------------------------------------------------------------

# Indique si Ansible devra demander le mot de passe sudo.
#
# `sudo -n true` ne convient pas : l'installation des prérequis, juste avant,
# a pu laisser un jeton sudo valide dans ce terminal, et le test réussit
# alors à tort. Ansible escalade depuis un contexte sans terminal, où ce
# jeton ne s'applique pas (tty_tickets, activé par défaut), et le playbook
# échoue en cours de route sur « sudo: il est nécessaire de saisir un mot de
# passe ».
#
# On cherche donc une règle NOPASSWD couvrant toutes les commandes. Dans le
# doute, on demande le mot de passe : le fournir inutilement est sans effet,
# l'oublier interrompt la configuration.
sudo_requires_password() {
  ! sudo -n -l 2>/dev/null | grep -qE 'NOPASSWD:[[:space:]]*ALL'
}

# Construit et lance la commande ansible-playbook.
run_playbook() {
  local -a command=(ansible-playbook "${PLAYBOOK}" --extra-vars "workstation_profile=${PROFILE}")

  if [[ -n "${TAGS}" ]]; then
    command+=(--tags "${TAGS}")
  fi

  if [[ -n "${SKIP_TAGS}" ]]; then
    command+=(--skip-tags "${SKIP_TAGS}")
  fi

  if [[ "${CHECK_MODE}" == "true" ]]; then
    command+=(--check --diff)
  fi

  if [[ -n "${VERBOSE}" ]]; then
    command+=("${VERBOSE}")
  fi

  # Mot de passe sudo, sauf si l'utilisateur en est réellement dispensé.
  if sudo_requires_password; then
    command+=(--ask-become-pass)
  fi

  # Déverrouillage du coffre uniquement si un coffre existe.
  if [[ -f "${VAULT_FILE}" ]]; then
    if [[ -f "${VAULT_PASS_FILE}" ]]; then
      command+=(--vault-password-file "${VAULT_PASS_FILE}")
    else
      command+=(--ask-vault-pass)
    fi
  fi

  info "Commande : ${command[*]}"
  printf '\n'

  (cd "${SCRIPT_DIR}" && "${command[@]}")
}

# Demande confirmation avant d'appliquer les changements.
confirm() {
  if [[ "${ASSUME_YES}" == "true" || "${CHECK_MODE}" == "true" ]]; then
    return 0
  fi

  local answer
  read -r -p "Appliquer le profil « ${PROFILE} » sur ${OS_NAME} ? [O/n] " answer

  # Réponse vide = oui : c'est le cas courant, l'utilisateur vient de
  # choisir son profil.
  if [[ -n "${answer}" && ! "${answer}" =~ ^[oOyY]$ ]]; then
    die "Abandon à la demande de l'utilisateur."
  fi
}

parse_arguments() {
  while (($# > 0)); do
    case "$1" in
      -p | --profile)
        [[ $# -ge 2 ]] || die "L'option $1 attend une valeur."
        PROFILE="$2"
        shift 2
        ;;
      -t | --tags)
        [[ $# -ge 2 ]] || die "L'option $1 attend une valeur."
        TAGS="$2"
        shift 2
        ;;
      --skip-tags)
        [[ $# -ge 2 ]] || die "L'option $1 attend une valeur."
        SKIP_TAGS="$2"
        shift 2
        ;;
      -c | --check)
        CHECK_MODE="true"
        shift
        ;;
      -y | --yes)
        ASSUME_YES="true"
        shift
        ;;
      -v | --verbose)
        VERBOSE="-v"
        shift
        ;;
      -vv)
        VERBOSE="-vv"
        shift
        ;;
      -vvv)
        VERBOSE="-vvv"
        shift
        ;;
      -l | --list)
        list_profiles
        exit 0
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die "Option inconnue : $1 (voir --help)" ;;
    esac
  done
}

main() {
  parse_arguments "$@"

  if [[ "${EUID}" -eq 0 ]]; then
    die "Ne pas lancer ce script en root : il configure le compte utilisateur courant et escalade les privilèges lorsque c'est nécessaire."
  fi

  [[ -f "${PLAYBOOK}" ]] || die "Playbook introuvable : ${PLAYBOOK}"

  detect_os
  info "Système détecté : ${OS_NAME}"

  ensure_dependencies
  install_collections

  if [[ -n "${PROFILE}" ]]; then
    validate_profile "${PROFILE}"
  else
    select_profile
  fi

  confirm
  run_playbook

  success "Configuration terminée (profil « ${PROFILE} »)."

  if [[ "${CHECK_MODE}" == "true" ]]; then
    warn "Mode simulation : aucune modification n'a été appliquée."
  fi

  return 0
}

main "$@"

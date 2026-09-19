#!/usr/bin/env bash
#
# Liste les paquets installés qui empêchent toute mise à niveau du système.
#
# Un paquet retiré des dépôts reste installé et n'est plus jamais reconstruit.
# S'il exige une version exacte d'un autre paquet (« depends=libcap=2.77 »),
# il interdit la mise à niveau de ce dernier, donc `pacman -Syu` dans son
# ensemble, donc toute installation : pacman ne prend pas en charge les mises
# à jour partielles.
#
# Sortie : une ligne par blocage, vide si le système n'en a aucun.

set -uo pipefail

readonly LOCAL_DB=/var/lib/pacman/local

# Version fournie par les dépôts pour un paquet, vide s'il n'y figure pas.
#
# `pacman --sync --info` lit la base de données sans résoudre de transaction,
# contrairement à `--print`, qui buterait sur le conflit même qu'on cherche à
# diagnostiquer et en recracherait le message ici. LC_ALL=C fige les
# étiquettes, traduites sinon.
version_en_depot() {
  LC_ALL=C pacman --sync --info "$1" 2>/dev/null |
    awk -F' *: *' '/^Version/ { print $2; exit }'
}

# Dépendances déclarées par un paquet installé, une par ligne.
dependances_installees() {
  local desc="${LOCAL_DB}/$1-$2/desc"

  if [[ ! -r "${desc}" ]]; then
    return
  fi

  awk '/^%DEPENDS%$/ { dans_bloc = 1; next }
       /^%/         { dans_bloc = 0 }
       dans_bloc && NF' "${desc}"
}

# `pacman --query --foreign` : les paquets installés qu'aucun dépôt ne
# fournit. Les paquets AUR en font partie et sont légitimes ; seuls comptent
# ici ceux qui figent la version d'un paquet des dépôts.
pacman --query --foreign 2>/dev/null | while read -r nom version; do
  dependances_installees "${nom}" "${version}" | while read -r dependance; do
    # Seules les égalités strictes bloquent : « >= » et « <= » restent
    # satisfaits par une version plus récente.
    case "${dependance}" in
      *'>='* | *'<='* | *'<'* | *'>'*) continue ;;
      *=*) ;;
      *) continue ;;
    esac

    exigee="${dependance#*=}"
    requis="${dependance%%=*}"
    disponible="$(version_en_depot "${requis}")"

    if [[ -n "${disponible}" && "${disponible}" != "${exigee}" ]]; then
      printf '%s %s exige %s=%s, les dépôts fournissent %s\n' \
        "${nom}" "${version}" "${requis}" "${exigee}" "${disponible}"
    fi
  done
done

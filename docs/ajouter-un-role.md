# Ajouter un rôle

Un rôle correspond à **une capacité** du poste (le shell, git, les
conteneurs, les applications graphiques…). Il doit fonctionner sur les deux
familles de distributions cibles et rester idempotent.

## 1. Créer la structure

```bash
mkdir -p roles/<nom>/{defaults,tasks,vars,meta}
```

| Répertoire | Contenu |
| --- | --- |
| `defaults/main.yml` | Tout ce qui est configurable, avec un commentaire par variable |
| `vars/Debian.yml`, `vars/Archlinux.yml` | Traductions de noms de paquets et chemins propres à la distribution |
| `tasks/main.yml` | Les tâches ; `tasks/<sujet>.yml` pour les parties conditionnelles |
| `meta/main.yml` | `galaxy_info` + `dependencies: []` |

Les variables du rôle sont **préfixées par son nom** (`docker_*` pour un rôle
`docker`). Les variables transverses (`workstation_user`, `workstation_home`,
`workstation_profile`…) viennent de `inventory/group_vars/all/main.yml`.

## 2. Écrire les tâches

La première tâche charge les variables de la distribution :

```yaml
---
- name: Charger les variables propres à la distribution
  ansible.builtin.include_vars: "{{ ansible_os_family }}.yml"
```

Ensuite, valider les entrées avant d'agir — un message d'erreur explicite
vaut mieux qu'un échec au milieu de l'installation :

```yaml
- name: Vérifier que les applications demandées sont connues pour cette distribution
  ansible.builtin.assert:
    that:
      - monrole_apps | difference(monrole_app_packages.keys() | list) | length == 0
    fail_msg: >-
      Applications sans paquet défini pour {{ ansible_os_family }} :
      {{ monrole_apps | difference(monrole_app_packages.keys() | list) | join(', ') }}.
      Compléter roles/monrole/vars/{{ ansible_os_family }}.yml.
    quiet: true
```

Puis les tâches elles-mêmes :

```yaml
- name: Installer les paquets du rôle
  become: true
  ansible.builtin.package:
    name: "{{ monrole_apps | map('extract', monrole_app_packages) | list }}"
    state: present
```

Règles à respecter :

- modules en FQCN (`ansible.builtin.package`, jamais `package`) ;
- `become: true` sur la tâche qui en a besoin, jamais sur le play ;
- pas de `command`/`shell` sans `creates` ou `changed_when` ;
- pas de test sur `ansible_distribution` dans une tâche : les différences
  vivent dans `vars/` ou dans un `tasks/<sujet>_{{ ansible_os_family }}.yml`
  inclus par `ansible.builtin.include_tasks`.

## 3. Déclarer le rôle dans le playbook

Dans `site.yml`, à la suite des autres :

```yaml
    - role: <nom>
      tags: [<nom>]
      when: "'<nom>' in workstation_roles"
```

Le `tags` permet de ne jouer que ce rôle via `./bootstrap.sh -t <nom>`.

## 4. Activer le rôle

- pour tous les postes : ajouter son nom à `common_roles` dans
  `profiles/common.yml` ;
- pour un profil seulement : l'ajouter à `profile_roles` dans
  `profiles/<profil>.yml`.

## 5. Vérifier

```bash
yamllint --strict .
ansible-lint                                        # doit passer en profil production
ansible-playbook site.yml --syntax-check -e workstation_profile=perso
./bootstrap.sh -p perso -t <nom> --check            # simulation du rôle seul
./bootstrap.sh -p perso -t <nom>                    # application réelle
./bootstrap.sh -p perso -t <nom>                    # doit être « changed=0 »
```

Le second passage sans changement est le test d'idempotence : s'il reste des
`changed`, une tâche n'est pas idempotente et doit être corrigée.

## 6. Paquets AUR (Arch / Manjaro)

Ne pas appeler `kewlfft.aur.aur` directement : passer par le rôle `aur`, qui
installe l'assistant si besoin.

```yaml
- name: Installer les paquets AUR du rôle
  ansible.builtin.include_role:
    name: aur
  vars:
    aur_packages: "{{ monrole_aur_packages }}"
  when:
    - ansible_os_family == 'Archlinux'
    - monrole_aur_packages | length > 0
```

## 7. Données sensibles

Un rôle ne lit jamais une variable `vault_*` directement. Il consomme une
variable publique, qu'un profil relie au coffre :

```yaml
# roles/monrole/defaults/main.yml
monrole_token: ""

# profiles/boulot.yml
monrole_token: "{{ vault_github_token }}"
```

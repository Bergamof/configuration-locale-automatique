# CLAUDE.md — mémoire du projet

> **À lire en premier, à chaque nouvelle session, avant d'explorer le dépôt.**
> Ce fichier résume l'architecture, les conventions et l'état d'avancement.
> Il doit être mis à jour dès qu'une décision structurante change.
>
> Dernière mise à jour : 2026-09-19

## 1. Objet du projet

Automatiser la configuration d'un poste de travail Linux après une
installation neuve : installation d'applications, configuration du shell,
de git, de SSH, de l'outillage de développement.

Le système est **modulaire** (un rôle = une capacité) et **piloté par
profils** : un tronc commun joué systématiquement, puis des rôles et des
variables propres au profil choisi.

## 2. Décisions structurantes

| Décision | Choix | Motif |
| --- | --- | --- |
| Technologie | **Ansible** (mode local, `connection: local`) | Idempotence, pas d'agent, multi-distro natif, rôles = modularité |
| Distributions cibles | **Manjaro** (famille `Archlinux`) et **Ubuntu** (famille `Debian`) | Demande utilisateur |
| Point d'entrée | `bootstrap.sh` (Bash) | Installe le minimum, choisit le profil, délègue à Ansible |
| Dotfiles | **Templates Jinja2 dans le dépôt** | Choix utilisateur : tout au même endroit, paramétrable par profil |
| Secrets | **Ansible Vault** (`inventory/group_vars/all/vault.yml`) | Choix utilisateur |
| Langue | Français pour le code, les commentaires, la doc et les commits | Cohérence avec l'utilisateur |

## 3. Arborescence

```
bootstrap.sh                 Point d'entrée : prérequis, choix du profil, lancement
site.yml                     Playbook unique ; monte les rôles selon le profil
ansible.cfg                  Configuration Ansible (inventaire, collections, sortie)
requirements.yml             Collections Ansible requises
inventory/
  hosts.yml                  Un seul hôte : localhost en connexion locale
  group_vars/all/
    main.yml                 Variables communes (workstation_*)
    vault.example.yml        Modèle du coffre ; vault.yml est chiffré et ignoré
profiles/
  common.yml                 Tronc commun : common_roles + valeurs partagées
  perso.yml                  Profil personnel : profile_roles + surcharges
  boulot.yml                 Profil professionnel : profile_roles + surcharges
roles/
  base/ shell/ git/ ssh/ dev/ desktop/ aur/
docs/
  ajouter-un-role.md         Procédure d'extension
```

## 4. Mécanique des profils (le cœur du système)

1. `bootstrap.sh` passe `-e workstation_profile=<nom>` à `ansible-playbook`.
2. `site.yml` charge `profiles/common.yml` puis `profiles/<profil>.yml`
   via `vars_files`.
3. `common.yml` définit `common_roles`, le profil définit `profile_roles`.
4. `inventory/group_vars/all/main.yml` calcule
   `workstation_roles: "{{ common_roles | union(profile_roles) }}"`.
5. Chaque rôle de `site.yml` porte `when: "'<rôle>' in workstation_roles"`
   et un `tags: [<rôle>]` permettant de n'en jouer qu'une partie.

**Précédence à retenir** : `vars_files` d'un play l'emporte sur les
`defaults/` d'un rôle et sur les `group_vars`. Un profil peut donc
surcharger n'importe quelle variable de rôle. Seul `-e` (extra-vars) le
dépasse — c'est ce qu'utilise `bootstrap.sh` pour le profil.

Ajouter un profil = déposer un `profiles/<nom>.yml` ; `bootstrap.sh` le
détecte automatiquement (`list_profiles` liste `profiles/*.yml` sauf
`common`).

## 5. Gestion du multi-distribution

- Jamais de test `ansible_distribution` dans une tâche : les différences
  vivent dans `roles/<rôle>/vars/{Archlinux,Debian}.yml`, chargés par
  `ansible.builtin.include_vars: "{{ ansible_os_family }}.yml"` en
  première tâche du rôle.
- Les rôles manipulent des **identifiants logiques** (`fd`, `bat`,
  `python`…) traduits en noms de paquets par un dictionnaire de la
  distribution (`base_package_names`, `dev_language_packages`,
  `desktop_app_packages`). Un `assert` en début de rôle signale tout
  identifiant sans traduction, avec le fichier à compléter.
- `ansible.builtin.package` est utilisé partout ; `base` rafraîchit le
  cache une fois pour toutes (`cache_Debian.yml` / `cache_Archlinux.yml`).
- L'AUR passe par le rôle `aur` (installe `paru`, puis `kewlfft.aur.aur`),
  inclus uniquement si `ansible_os_family == 'Archlinux'` et si la liste
  `*_aur_packages` du rôle appelant est non vide.

## 6. Conventions de code (impératives)

**Ansible**

- Modules toujours en FQCN (`ansible.builtin.package`, non `package`).
- Un nom de tâche par tâche, en français, commençant par une majuscule et
  un verbe à l'infinitif ; une variable Jinja seulement en fin de nom.
- Variables préfixées par le nom du rôle (`shell_*`, `git_*`…) ;
  les variables transverses sont préfixées `workstation_*`.
- `become: true` au niveau de la tâche, jamais sur le play.
- Tout ce qui est configurable vit dans `defaults/main.yml` avec un
  commentaire d'explication ; `vars/` ne contient que le non-surchargeable
  (traductions de paquets par distribution).
- Idempotence obligatoire : pas de `command`/`shell` sans `creates` ou
  `changed_when`.
- `ansible-lint` doit passer en **profil `production`** (aucune exception
  dans `skip_list`).

**Bash**

- `set -euo pipefail`, fonctions courtes, variables en majuscules pour la
  configuration globale, `readonly` pour les constantes.
- Attention au piège `set -e` : ne jamais terminer une fonction ou une
  itération par `[[ cond ]] && commande` (statut 1 si la condition est
  fausse → arrêt du script). Utiliser un `if`.
- `shellcheck --severity=style` et `shfmt --indent 2 --case-indent`
  doivent passer sans diff.

**Git**

- Branches nommées d'après le changement porté :
  `feat/<sujet>`, `fix/<sujet>`, `docs/<sujet>`.
- Messages de commit en français, style impératif.

## 7. Commandes utiles

```bash
./bootstrap.sh                     # menu interactif
./bootstrap.sh -p perso            # profil direct
./bootstrap.sh -p boulot -t git    # un seul rôle
./bootstrap.sh -p perso --check    # simulation (--check --diff)
./bootstrap.sh --list              # profils disponibles

# Vérifications (identiques à la CI)
yamllint --strict .
ansible-lint
shellcheck --severity=style bootstrap.sh
shfmt --indent 2 --case-indent --diff bootstrap.sh
ansible-playbook site.yml --syntax-check -e workstation_profile=perso

# Coffre
ansible-vault encrypt inventory/group_vars/all/vault.yml
ansible-vault edit inventory/group_vars/all/vault.yml
```

## 8. Pièges rencontrés (ne pas les réintroduire)

- `stdout_callback = yaml` **n'existe plus** (retiré de `community.general`
  v12) : utiliser `result_format = yaml` dans `ansible.cfg`.
- `vault_password_file` dans `ansible.cfg` fait échouer toute commande si
  le fichier est absent → le déverrouillage est géré par `bootstrap.sh`
  (`--vault-password-file` si `.vault_pass` existe, sinon
  `--ask-vault-pass`, et rien du tout si `vault.yml` n'existe pas).
- `galaxy_info.platforms` n'accepte que les noms du schéma Galaxy :
  `ArchLinux` (et non `Archlinux`), `Ubuntu`, versions `all`.
- Les descriptions de `meta/main.yml` contenant ` : ` doivent être
  entre guillemets (sinon YAML invalide).
- `ansible.builtin.systemd_service` exige ansible-core ≥ 2.16 ;
  on utilise `ansible.builtin.systemd`, compatible plus largement
  (Ubuntu 24.04 fournit 2.16, mais pas les versions antérieures).
- `.yamllint` doit contenir `comments-indentation: false`, sinon
  `ansible-lint` refuse de réutiliser la configuration.

## 9. État d'avancement

**Fait**

- Socle complet : `bootstrap.sh`, `site.yml`, inventaire, profils
  `perso` / `boulot`.
- Rôles `base`, `shell`, `git`, `ssh`, `dev`, `desktop`, `aur`.
- Qualité : `.yamllint`, `.ansible-lint` (profil production),
  `.pre-commit-config.yaml`, CI GitHub Actions (shellcheck, shfmt,
  yamllint, ansible-lint, `--syntax-check` par profil).
- Vérifié : lint au vert, `--syntax-check` sur les deux profils, rendu
  réel de tous les gabarits Jinja2.

**Non vérifié / à faire**

- Aucune exécution de bout en bout sur une vraie machine Manjaro ou
  Ubuntu (l'environnement de développement ne le permet pas). Le premier
  passage réel doit se faire avec `--check` puis sans.
- Tests Molecule (conteneurs Ubuntu + Arch) non mis en place : c'est la
  prochaine étape naturelle pour tester l'idempotence en CI.
- Le profil `boulot` exige `vault_boulot_email` : sans coffre, le rôle
  `git` s'arrête sur un `assert` explicite. Comportement voulu.
- `firefox` sur Ubuntu est un paquet de transition vers le snap.

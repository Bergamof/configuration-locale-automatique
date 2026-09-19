# Configuration locale automatique

Configuration automatisée d'un poste de travail Linux après une installation
neuve : applications, shell, git, SSH, outillage de développement.

Un seul script à lancer, un profil à choisir, le reste est appliqué par
[Ansible](https://docs.ansible.com/) — de façon **idempotente** : rejouer la
configuration ne casse rien et ne modifie que ce qui a dérivé.

## Distributions prises en charge

| Distribution | Famille Ansible | Gestionnaire |
| --- | --- | --- |
| Manjaro, Arch | `Archlinux` | `pacman` + AUR (`paru`) |
| Ubuntu, Debian | `Debian` | `apt` |

## Démarrage rapide

```bash
git clone https://github.com/Bergamof/configuration-locale-automatique.git
cd configuration-locale-automatique
./bootstrap.sh
```

Le script installe les prérequis (git, Ansible, collections), propose les
profils disponibles, puis applique la configuration.

> Ne pas lancer `bootstrap.sh` avec `sudo` : il configure le compte
> utilisateur courant et escalade les privilèges uniquement là où c'est
> nécessaire.

### Options

```
-p, --profile NOM     Profil à appliquer (sinon menu interactif)
-t, --tags LISTE      Ne jouer que ces rôles (base, shell, git, ssh, dev, desktop)
    --skip-tags LISTE Jouer tout sauf ces rôles
-c, --check           Simulation : affiche les changements sans rien appliquer
-y, --yes             Pas de confirmation
-v, --verbose         Sortie détaillée (-vv, -vvv)
-l, --list            Lister les profils
-h, --help            Aide
```

```bash
./bootstrap.sh -p boulot              # profil professionnel complet
./bootstrap.sh -p perso --check       # voir ce qui changerait
./bootstrap.sh -p perso -t shell,git  # seulement le shell et git
```

## Fonctionnement

```
bootstrap.sh ──> site.yml ──┬── tronc commun  : base, shell, git, ssh
                            └── profil choisi : dev, desktop, …
```

- **Tronc commun** (`profiles/common.yml`) : joué quel que soit le profil.
- **Profil** (`profiles/perso.yml`, `profiles/boulot.yml`) : ajoute des rôles
  et surcharge les variables (identité git, applications, langages…).

Les rôles disponibles :

| Rôle | Contenu |
| --- | --- |
| `base` | Mise à niveau du système, outils en ligne de commande essentiels, fuseau horaire, locale |
| `shell` | zsh/bash, alias, variables d'environnement, invite Starship |
| `git` | `~/.gitconfig`, alias, ignore global, identité conditionnelle par répertoire |
| `ssh` | `~/.ssh/config`, génération de clé ed25519, clés autorisées |
| `dev` | Langages, outillage de compilation, Docker |
| `desktop` | Applications graphiques, Flatpak, polices |
| `aur` | Assistant AUR (`paru`), utilisé par les autres rôles sur Arch |

## Personnalisation

### Modifier un profil existant

Tout est dans `profiles/<profil>.yml` : liste des rôles, applications,
langages, identité git. Les variables disponibles sont documentées dans
`roles/<rôle>/defaults/main.yml`.

```yaml
# profiles/perso.yml
desktop_apps:
  - firefox
  - vlc
  - gimp        # ajout
dev_languages:
  - python
  - rust        # ajout
```

### Ajouter un profil

Créer `profiles/<nom>.yml` avec au minimum `profile_roles`. Le script le
détecte automatiquement.

```yaml
---
profile_roles:
  - dev
workstation_full_name: "Prénom Nom"
workstation_email: "prenom@example.com"
```

### Ajouter un rôle

Voir [`docs/ajouter-un-role.md`](docs/ajouter-un-role.md).

### Ajouter une application

Les rôles manipulent des identifiants logiques traduits en noms de paquets
par distribution. Pour ajouter une application, compléter les deux fichiers
de traduction :

```yaml
# roles/desktop/vars/Debian.yml
desktop_app_packages:
  inkscape: inkscape

# roles/desktop/vars/Archlinux.yml
desktop_app_packages:
  inkscape: inkscape
```

puis la référencer dans un profil (`desktop_apps: [..., inkscape]`).

## Secrets (Ansible Vault)

Les données sensibles (adresses professionnelles, jetons, clés publiques)
vivent dans un coffre chiffré.

```bash
cp inventory/group_vars/all/vault.example.yml inventory/group_vars/all/vault.yml
# renseigner les valeurs, puis chiffrer :
ansible-vault encrypt inventory/group_vars/all/vault.yml
```

`bootstrap.sh` demande le mot de passe du coffre uniquement si
`vault.yml` existe. Pour éviter la saisie, placer le mot de passe dans
`.vault_pass` (ignoré par git).

Convention : les variables du coffre sont préfixées `vault_` et ne sont
jamais utilisées directement par un rôle — un profil les affecte à une
variable publique :

```yaml
# profiles/boulot.yml
workstation_email: "{{ vault_boulot_email }}"
```

## Développement

```bash
pipx install pre-commit && pre-commit install

yamllint --strict .
ansible-lint                                   # profil « production »
shellcheck --severity=style bootstrap.sh
shfmt --indent 2 --case-indent --diff bootstrap.sh
ansible-playbook site.yml --syntax-check -e workstation_profile=perso
```

### Tests

Le tronc commun est réellement appliqué dans des conteneurs Ubuntu 24.04 et
Arch, puis vérifié — y compris son idempotence (une seconde exécution ne doit
produire aucun changement).

```bash
pip install molecule docker
ansible-galaxy collection install -r requirements.yml

molecule test                        # séquence complète, puis nettoyage
molecule converge                    # appliquer sans détruire, pour itérer
molecule login -h molecule-ubuntu    # inspecter un conteneur
molecule destroy                     # nettoyer
```

Docker doit être disponible localement. Les rôles `dev` et `desktop` sont
écartés du scénario : Docker dans Docker, Flatpak et les applications
graphiques ne sont pas testables en conteneur.

Ces vérifications sont rejouées par la CI GitHub Actions sur chaque
*pull request*. Les conventions du projet sont décrites dans
[`CLAUDE.md`](CLAUDE.md).

## Licence

AGPL-3.0 — voir [LICENSE](LICENSE).

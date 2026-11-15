# Depot `sudo-studio-packager`

## Role

**Packaging uniquement** : cet assembleur construit l'installateur Windows (et, plus tard, les
paquets Linux). Il ne contient **aucun code produit** : ni backend, ni runtime, ni extension.

Les builds se font dans `juleszackaria-lab/Sudo-studio` :

- `00-test-suite.yml` : tests.
- `01-backend-build.yml` : artefact `backend-exe`.
- `02-runtime-build.yml` : artefact `runtime-exe`.

Ce depot telecharge ces deux artefacts, les assemble avec l'editeur, puis signe et emballe.
Le workflow de fumee sur un paquet **installe** (`06-smoke-installed.yml`) est reste dans
`Sudo-studio` ; il consomme un installateur deja construit, donc sa place logique serait ici,
a cote de `.github/workflows/03-package.yml`.

## Regle de travail

**Tout le travail se fait sur `main`. Aucune autre branche n'est conservee.**
Une modification = un commit sur `main` (ou une pull request dont la branche est supprimee apres
fusion). L'historique de `main` ne se reecrit pas : pas de force-push.

## References (pins)

Le packaging ne devine jamais quoi assembler. Trois valeurs, en tete de
`.github/workflows/03-package.yml`, decident de tout :

| Variable | Valeur attendue |
|---|---|
| `SUDO_STUDIO_REF` | SHA complet (40 caracteres) de `main` de `Sudo-studio` |
| `BACKEND_RUN_ID` | identifiant du run **01** construit sur ce SHA |
| `RUNTIME_RUN_ID` | identifiant du run **02** construit sur ce SHA |

Le workflow refuse de produire un paquet si ces trois valeurs ne sont pas coherentes entre elles :
il verifie que le SHA du run 01 et celui du run 02 valent `SUDO_STUDIO_REF`, que les deux runs sont
en `success`, et que les artefacts atteignent la taille minimale. Un paquet ne peut donc pas etre
construit a partir d'un code non teste.

## Mise a jour d'une epingle

1. Pousser sur `main` de `Sudo-studio`.
2. Attendre la fin des runs `01` et `02` construits sur ce commit ; ils doivent etre verts.
3. Reporter dans `03-package.yml` : `SUDO_STUDIO_REF` (le SHA), puis `BACKEND_RUN_ID` et
   `RUNTIME_RUN_ID` (les deux identifiants de run), **les trois ensemble**.
4. Lancer « SudoStudio Stable Build » sur `main`.

## Workflows de ce depot

| Fichier | Role | Etat |
|---|---|---|
| `03-package.yml` | « SudoStudio Stable Build » : installateur Windows + fumee sur paquet installe | actif |
| `04-package-linux.yml` | paquets Linux | **NON TRAITE (decision de l'utilisateur)** |
| `05-linux-smoke.yml` | fumee Linux en conteneurs | **NON TRAITE (decision de l'utilisateur)** |
| `test.yml` | « Test Runner » | actif |

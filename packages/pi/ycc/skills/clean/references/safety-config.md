# Project Cleaner Safety Configuration

## Contents

- Protected Directories
- Protected Files
- Security-Sensitive Patterns
- Emergency Stop Conditions
- User-Defined Exclusions

Protected directories, files, and patterns that should **NEVER** be flagged for removal.

---

## Protected Directories

### Version Control

`.git/`, `.svn/`, `.hg/`, `.bzr/`

### Package Manager Dependencies

`node_modules/`, `.pnpm/`, `.yarn/`, `bower_components/`, `vendor/`, `Godeps/`

### Virtual Environments

`.venv/`, `venv/`, `env/`, `ENV/`, `virtualenv/`, `.virtualenvs/`, `__pypackages__/`

### Build Output Directories

`dist/`, `build/`, `out/`, `.next/`, `.nuxt/`, `target/`, `bin/`, `obj/`

### IDE and Editor Directories

`.vscode/`, `.idea/`, `.eclipse/`, `.settings/`

### Cache and Temporary Directories

`.cache/`, `.temp/`, `.tmp/`, `tmp/`, `.sass-cache/`, `.pytest_cache/`, `.mypy_cache/`, `.ruff_cache/`, `__pycache__/`

### Framework-Specific Directories

`.angular/`, `.svelte-kit/`, `.turbo/`, `.parcel-cache/`, `coverage/`, `.nyc_output/`

### Project-Specific Protected Directories

`logs/`, `data/`, `uploads/`, `public/uploads/`, `storage/`, `.claude/`, `.cursor/`, `.config/`

---

## Protected Files

### Version Control

`.gitignore`, `.gitattributes`, `.gitmodules`, `.git-blame-ignore-revs`

### Project Metadata

`package.json`, `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `Gemfile`, `Gemfile.lock`, `go.mod`, `go.sum`, `Cargo.toml`, `Cargo.lock`, `composer.json`, `composer.lock`, `pyproject.toml`, `poetry.lock`, `requirements.txt`, `setup.py`, `setup.cfg`

### Configuration Files

`.editorconfig`, `.nvmrc`, `.node-version`, `.ruby-version`, `.python-version`, `tsconfig.json`, `jsconfig.json`, `.eslintrc`, `.eslintrc.*`, `.prettierrc`, `.prettierrc.*`, `babel.config.*`, `.babelrc`, `jest.config.*`, `vitest.config.*`, `vite.config.*`, `webpack.config.*`, `rollup.config.*`

### Docker and Container Files

`Dockerfile`, `.dockerignore`, `docker-compose.yml`, `docker-compose.yaml`, `.env.example`, `.env.sample`

### Documentation Files

`README.md`, `README`, `LICENSE`, `LICENSE.md`, `LICENSE.txt`, `COPYING`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `CHANGELOG.md`, `SECURITY.md`, `SUPPORT.md`

### CI/CD Configuration

`.github/workflows/*.yml`, `.gitlab-ci.yml`, `.travis.yml`, `.circleci/config.yml`, `Jenkinsfile`, `azure-pipelines.yml`, `.buildkite/pipeline.yml`

### Environment and Runtime Files

`.env.example`, `.env.sample`, `.env.template`, `Makefile`, `Rakefile`, `justfile`, `Procfile`

---

## Security-Sensitive Patterns

Flag for **SECURITY REVIEW**, not automatic removal:

### Environment Files

`.env`, `.env.local`, `.env.development`, `.env.production`, `.env.staging`, `.env.test`, `*.env`

### Credential Files

`credentials.json`, `credentials.yml`, `auth.json`, `secrets.json`, `secrets.yml`, `*.secrets`, `*.credentials`, `*-credentials.*`

### Key Files

`*.key`, `*.pem`, `*.p12`, `*.pfx`, `*.crt`, `*.cer`, `*.der`, `id_rsa`, `id_ed25519`

### Database Files

`*.db`, `*.sqlite`, `*.sqlite3`, `*.db3`

---

## Emergency Stop Conditions

Abort cleanup immediately if:

1. No `.git` directory found
2. Target is root or home directory
3. Protected directory in removal list
4. Over 1000 files flagged
5. Total size over 10GB

---

## User-Defined Exclusions

### .cleanupignore

If present in target directory, add patterns to protected list (same format as .gitignore).

### .cleanup-safety.yml

Custom safety rules in YAML format with `protected_directories`, `protected_files`, `protected_patterns`, `security_patterns` keys.

# Push this repo to your own GitHub (5 minutes)

The folder `pasarguard/repo` in this workspace **is already a git repository with
one commit**. You only need to point it at your GitHub account and push.

Download `pasarguard-repo.zip` from the workspace, unzip it on your machine, and
follow whichever route you prefer.

---

## Route A — GitHub CLI (fastest)

```bash
cd pasarguard-repo
gh auth login                 # once
gh repo create pasarguard-panel --private --source=. --remote=origin --push
```

Done. Your repo now exists at `https://github.com/<you>/pasarguard-panel`.

---

## Route B — plain git

1. On github.com: **New repository** → name it (e.g. `pasarguard-panel`) →
   **Private** → do **not** add README/.gitignore/licence → Create.
2. Then:

```bash
cd pasarguard-repo
git remote add origin https://github.com/<YOUR-USER>/pasarguard-panel.git
git branch -M main
git push -u origin main
```

If GitHub asks for a password, use a **Personal Access Token** (Settings →
Developer settings → Tokens (classic) → `repo` scope) as the password, or use SSH:

```bash
git remote set-url origin git@github.com:<YOUR-USER>/pasarguard-panel.git
```

---

## Route C — you have no files yet, only this workspace

Ask me and I'll regenerate the archive; the repository content is fully
reproducible from the workspace.

---

## After the push

Clone and deploy on any VPS:

```bash
git clone https://github.com/<YOUR-USER>/pasarguard-panel.git
cd pasarguard-panel
sudo ./deploy.sh
```

Update the server later with:

```bash
cd pasarguard-panel && git pull && sudo ./deploy.sh --update
```

## Forking

Forking on GitHub works out of the box: the fork is the same tree, and the
fork's owner can clone it and run `sudo ./deploy.sh` on their own server. Nothing
in the repo contains secrets — `.env` is generated on first run and is
git-ignored, so every fork gets its own random admin password.

## Before you make the repo public

* It packages third-party software — read `LICENSE-NOTICE.md` first.
* `git log` contains no credentials (checked), but if you ever add any, rotate
  them; removing a commit is not enough.
* Recommended repo settings: **Settings → General → Danger zone** for who can
  fork (private repos can restrict it), and enable **secret scanning**.

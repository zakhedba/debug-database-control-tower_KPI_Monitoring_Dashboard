# Publish to GitHub

1. Review every source file, the DOCX metadata, and `SECURITY.md`. Remove organisation-specific information before creating any commit.
2. On github.com choose **New repository**, name it `debug-database-control-tower`, select **Public** only after review, and do not initialise it with a second README.
3. Unzip this bundle locally, open a terminal in the project root and run:

```bash
git init
git add .
git status
git diff --cached --stat
git commit -m "Initial public DBA KPI evidence portfolio"
git branch -M main
git remote add origin https://github.com/YOUR-USERNAME/debug-database-control-tower.git
git push -u origin main
```

4. Confirm the resulting GitHub page renders README and all linked files.
5. Add tested synthetic evidence and screenshots to subsequent pull requests; never upload live exports.
6. Keep secrets and private operational evidence in a separate access-controlled store, not on public GitHub.

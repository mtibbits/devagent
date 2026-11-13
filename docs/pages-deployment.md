# Publishing the onboarding site to GitHub Pages

`docs-site/` is rendered by `scripts/build-docs-site.sh` and published by
`.github/workflows/publish-docs-site.yml`. **Publishing is off by default**,
and during the website 2.0 work it is held off on purpose (the deploy hold in
`docs-site/README.md`).
The workflow's deploy half runs only when all three hold: the repository is
`mtibbits/devagent`, the ref is `refs/heads/master`, and the repository variable
`DOCS_SITE_DEPLOY` is exactly `true`. Until then every run stops after building
and uploads the rendered site as a plain `docs-site` artifact you can download
and open.

## Build it locally

```sh
bash scripts/build-docs-site.sh --out /tmp/devagent-site
```

Needs pandoc 3.x, awk and python3 3.8+ whose html.parser carries the 2025
security fixes (`DEVAGENT_PYTHON` names another interpreter; the build exits 3
on one without them). `--out` must be absent or empty; the script never deletes.
A build that breaks the site's fetch policy exits 7, and one whose fetch scan
did not complete exits 8 (`docs-site/README.md`, "What the site may load").
Open `/tmp/devagent-site/index.html` (checked under the site CSP on
2026-11-12: Edge 157 loads the site's own CSS, JS and images from `file://`;
Firefox 160 applies no meta CSP to `file://` pages).

## Turning publishing on (operator)

These steps were executed against this repository on 2026-09-18; the
transcript is a comment on #465, and the two workflow runs it names are
35308905744 (the first `master` run after the pipeline merged: build, deploy
skipped with the gate off) and 35309395578 (the switch-on run: build and
deploy). What follows is what happened, not what was expected; outcomes that
were NOT observed are marked as such, so the next operator knows which
branches are still untested.

1. Enable Pages with the workflow build type, and note the site URL it reports:

   ```sh
   gh api -X POST repos/mtibbits/devagent/pages -f build_type=workflow
   gh api repos/mtibbits/devagent/pages -q .html_url
   ```

2. Read the `github-pages` environment's branch policy **before** changing it:

   ```sh
   gh api repos/mtibbits/devagent/environments/github-pages -q .deployment_branch_policy
   gh api repos/mtibbits/devagent/environments/github-pages/deployment-branch-policies -q '.branch_policies[].name'
   ```

   Observed on 2026-09-18: enabling Pages in step 1 created the `github-pages`
   environment immediately, and it already carried
   `{"custom_branch_policies":true,"protected_branches":false}` with `master`
   listed — nothing to add.
   Not observed (untested branches):
   - a `null` policy — any branch may deploy; nothing to do.
   - a 404 — the environment was not created: enabling Pages does not
     necessarily create it, the first deploy does, and a new environment has
     no branch restriction; proceed to step 3 and re-read this after that run.
   - a custom policy that omits `master` — add it:

     ```sh
     gh api -X POST repos/mtibbits/devagent/environments/github-pages/deployment-branch-policies \
       -f name=master -f type=branch
     ```

   A missing policy fails only the deploy job, with the build job still green.

3. Switch the gate on, then trigger a fresh run:

   ```sh
   gh variable set DOCS_SITE_DEPLOY --body true -R mtibbits/devagent
   gh workflow run publish-docs-site.yml -R mtibbits/devagent --ref master
   gh run watch -R mtibbits/devagent
   ```

   Use a fresh run, not a re-run of an old one: a Pages artifact expires.

   Observed on 2026-09-18: the dispatched run (35309395578) built and deployed
   `43f9e27`; the earlier `master` run (35308905744) had built and skipped the
   deploy with the gate off, which is the gate working.

4. Check every page and every moved-page stub, from a checkout of `master`.
   The list comes from the directory and `docs-site/moved.txt`, so it cannot
   go stale:

   ```sh
   base="$(gh api repos/mtibbits/devagent/pages -q .html_url)"
   base="${base%/}/"
   {
     for f in docs-site/*.md docs-site/*.html; do
       [ -e "$f" ] || continue
       p="$(basename "$f")"; p="${p%.*}"; [ "$p" = README ] || echo "$p"
     done
     awk '!/^[ \t]*(#|$)/ { print $1 }' docs-site/moved.txt
   } | while read -r p; do
     printf '%s %s\n' "$(curl -s -o /dev/null -w '%{http_code}' "${base}${p}.html")" "${p}.html"
   done
   ```

   Every line should start with `200`.

## Turning publishing off

```sh
gh variable delete DOCS_SITE_DEPLOY -R mtibbits/devagent
```

The published site stays up until Pages itself is disabled; this only stops new
deploys. The website 2.0 deploy hold (`docs-site/README.md`) is the same
switch, set rather than deleted:
`gh variable set DOCS_SITE_DEPLOY --body false -R mtibbits/devagent`.

## After the flip (2026-09-18)

Every page confirmed live (step 4: six `200`s); `README.md` and the repository
homepage field carry https://mtibbits.github.io/devagent/; the clean-machine
install walkthrough is attached to #465 and its two findings are fixed on the
install page. Nothing from the flip itself is owed. A docs push to `master`
now deploys for real; "Turning publishing off" above is the off switch.

# Publishing the onboarding site to GitHub Pages

`docs-site/` is rendered by `scripts/build-docs-site.sh` and published by
`.github/workflows/publish-docs-site.yml`. **Publishing is off by default.**
The workflow's deploy half runs only when all three hold: the repository is
`mtibbits/devagent`, the ref is `refs/heads/master`, and the repository variable
`DOCS_SITE_DEPLOY` is exactly `true`. Until then every run stops after building
and uploads the rendered site as a plain `docs-site` artifact you can download
and open.

## Build it locally

```sh
bash scripts/build-docs-site.sh --out /tmp/devagent-site
```

Needs pandoc 3.x. `--out` must be absent or empty; the script never deletes.
Open `/tmp/devagent-site/index.html`.

## Turning publishing on (operator, after the repository is public)

GitHub Pages is not available to this repository while it is private
(decision record: #463). The steps below were therefore **written before they
could be run**. The read-only calls were exercised against `mtibbits/volk`,
which publishes the same way; the state-changing calls have not been executed
against this repository. Whoever runs them first corrects this section from
what actually happened.

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

   If the first prints `null` or nothing, any branch may deploy and there is
   nothing to do.
   If it reports `custom_branch_policies: true` and the second does not list
   `master`, add it:

   ```sh
   gh api -X POST repos/mtibbits/devagent/environments/github-pages/deployment-branch-policies \
     -f name=master -f type=branch
   ```

   Whether a default branch needs this is not yet known. A missing policy fails
   only the deploy job, with the build job still green.

3. Switch the gate on, then trigger a fresh run:

   ```sh
   gh variable set DOCS_SITE_DEPLOY --body true -R mtibbits/devagent
   gh workflow run publish-docs-site.yml -R mtibbits/devagent --ref master
   gh run watch -R mtibbits/devagent
   ```

   Use a fresh run, not a re-run of an old one: a Pages artifact expires.

4. Check every page. The list comes from the directory, so it cannot go stale:

   ```sh
   base="$(gh api repos/mtibbits/devagent/pages -q .html_url)"
   for f in docs-site/*.md; do
     p="$(basename "$f" .md)"; [ "$p" = README ] && continue
     printf '%s %s\n' "$(curl -s -o /dev/null -w '%{http_code}' "${base}${p}.html")" "${p}.html"
   done
   ```

   Every line should start with `200`.

## Turning publishing off

```sh
gh variable delete DOCS_SITE_DEPLOY -R mtibbits/devagent
```

The published site stays up until Pages itself is disabled; this only stops new
deploys.

## What is still owed after the flip

Tracked on #465, which stays open until these are done: every page confirmed
live (step 4 above), a clean-machine install walkthrough transcript, the live
URL added to `README.md` and the repository's homepage field, and this file's
"Turning publishing on" section corrected from the real transcript.

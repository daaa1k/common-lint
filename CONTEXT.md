# Common lint

Common lint is a container GitHub Action that runs repository-wide lint and security checks. This context also includes the maintenance workflow for the container image and its bundled tools.

## Language

**Dockerfile dependency**:
An externally released tool or pinned image reference embedded in the root `Dockerfile`.
_Avoid_: apt package, runtime package

**Update script**:
A local maintenance script that refreshes eligible Dockerfile dependencies to newer releases and matching checksums.
_Avoid_: Renovate replacement, release bot

**Eligibility window**:
The minimum published age a dependency release or resolved image digest must satisfy before the Update script may adopt it.
_Avoid_: cooldown, grace period

**Update candidate**:
A Dockerfile dependency evaluated independently for update against the Eligibility window.
_Avoid_: batch update, global release

**GitHub API token**:
A token used by the Update script to query GitHub APIs during local maintenance runs.
_Avoid_: Actions GITHUB_TOKEN, anonymous API access

## Relationships

- An **Update script** evaluates each **Update candidate** independently
- An **Update candidate** is updated only when it satisfies the **Eligibility window**
- A **Dockerfile dependency** may become an **Update candidate** when it is managed by the **Update script**
- A **GitHub API token** is required when the **Update script** queries GitHub-hosted release metadata

## Example dialogue

> **Dev:** "Does the **Update script** wait until every **Update candidate** is old enough before changing the `Dockerfile`?"
> **Domain expert:** "No. Each **Update candidate** is checked on its own, and only the ones past the **Eligibility window** are updated."

## Flagged ambiguities

- "dependency update" was used to mean both Dockerfile-pinned tools and OS package refreshes — resolved: in this context, the Update script excludes `apt-get install` package versions
- "`GITHUB_TOKEN`" was used to mean both the Actions-provided token and a local user token — resolved: this context uses **GitHub API token** as the canonical term

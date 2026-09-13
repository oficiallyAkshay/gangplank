# gangplank

Hands-off, reliable deploys to the Mac that runs your agents. Merge it, and your machine is running it.

![inbound ports](https://img.shields.io/badge/inbound%20ports-0-brightgreen) ![secrets to rotate](https://img.shields.io/badge/secrets%20to%20rotate-0-blueviolet) ![runtime dependencies](https://img.shields.io/badge/runtime%20dependencies-0-ff69b4) ![platform](https://img.shields.io/badge/platform-macOS%20%C2%B7%20launchd-blue) ![shellcheck](https://img.shields.io/badge/shellcheck-clean-brightgreen) ![coverage](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2FoficiallyAkshay%2Fgangplank%2Fbadges%2Fbadges%2Fcoverage.json) ![license](https://img.shields.io/badge/license-MIT-orange)

gangplank turns a GitHub self-hosted runner into a deploy-only agent for one Mac. A merge to main lands on the machine in seconds, through one door, never by force. No open port, no tunnel, no secret to rotate.

Built for machines that run long-lived things: OpenClaw, Claude Code loops, daemons, dashboards.

It is made for the way that machine actually gets developed: some changes arrive as merged PRs from wherever you are, and some you make by hand sitting at the box. gangplank keeps both true at once. Your on-box edits are never overwritten by a deploy, and a deploy never waits for you to clean them up.

## What gangplank adds

The runner and git do the transport. gangplank adds what neither does:

- **The gate.** The runner will run any job it is handed; the gate refuses all but one named workflow on one named branch, fails closed if it cannot verify, and makes no network calls. That is what makes a self-hosted runner safe on a machine that holds secrets.
- **Refuse instead of force.** Divergence, a failed fetch, or a tree that cannot fast-forward stops the deploy and says why. Never a reset.
- **Park, do not re-apply, and only when a pull actually happens; a failed pull puts them back.** Your uncommitted edits on the box are set aside under a named stash and left there. A deploy never edits your working files.
- **Self-heal from a stranded checkout.** A box left on a branch that has since squash-merged is put back on main and deployed.
- **Install only what changed.** Dependencies are reinstalled only in the packages whose manifest moved in this deploy.
- **Daemons ship with their code.** A new or changed launchd definition is loaded on the deploy that carries it; one renamed to disabled is unloaded.
- **Restarts launchd would drop.** Rapid file changes get coalesced into one event and one daemon loses; gangplank kicks it explicitly.
- **Parallel-session cleanup that cannot delete live work.** A worktree goes only when its PR merged, its tree is clean, and no session holds it.
- **Failure-only alerting, to whatever you point it at.** On a failed deploy it runs the command you name, once; on the first real deploy after that it runs your recovery command. Nothing on success, and nothing at all if you name no command; the red run on GitHub is the record.

## Use it

On the Mac, once:

```bash
git clone https://github.com/oficiallyAkshay/gangplank ~/.gangplank/src
~/.gangplank/src/bin/gangplank install --repo you/your-repo
```

That registers a GitHub runner on the machine, runs it as a launchd service, and places the gate outside any checkout so no branch can edit it. `gangplank status`, `gangplank dry-run` and `gangplank uninstall` are the other three verbs.

In your repo, the deploy workflow (full version with every option in `examples/deploy.yml`):

```yaml
on:
  push: { branches: [main] }
  schedule: [{ cron: "17 * * * *" }]
concurrency: { group: deploy, cancel-in-progress: false }
jobs:
  deploy:
    runs-on: [self-hosted, macOS, gangplank]
    steps:
      - uses: oficiallyAkshay/gangplank@v0
        with:
          repo: /Users/you/your-checkout
```

Merge to main, and the Mac has it in seconds.

## How it sits

Nothing on the Mac listens to the internet. The runner asks GitHub for work over an outbound connection, and the gate decides whether that work may run.

```mermaid
flowchart LR
  subgraph GH[GitHub]
    PR[Pull request] -->|merge| M[main]
    M -->|push event| Q[Actions job queue]
  end
  subgraph MAC[Your Mac]
    R[Self-hosted runner<br/>launchd service] --> G{Gate<br/>one workflow, one branch}
    G -->|refused| X[Job fails before any step]
    G -->|allowed| D[Deploy script]
    D --> C[(Repo checkout)]
    D --> H[Hooks<br/>install deps · load daemons · kick]
    H --> S[launchd daemons]
  end
  Q -.->|outbound long-poll<br/>no inbound port| R
  D -->|only on failure| SL[Your alert command]
```

## One deploy

Every branch that is not the happy path ends the run red with its cause. Nothing is forced, and nothing of yours is overwritten.

```mermaid
flowchart TD
  A[Job assigned to the runner] --> B{Gate<br/>deploy workflow on main?}
  B -- no --> B1[Refused. Red before any step]
  B -- yes --> C[Fetch, prune gone branches]
  C --> D{Checkout left on a<br/>squash-merged branch?}
  D -- yes --> D1[Switch back to main]
  D -- no --> E
  D1 --> E{Uncommitted edits?}
  E -- yes --> E1[Park under a named stash]
  E -- no --> F
  E1 --> F{Fast-forward possible?}
  F -- no, diverged --> F1[Stop. Red with the cause]
  F -- yes --> G[Fast-forward pull]
  G --> H[Install deps where a manifest changed]
  H --> I[Load new or changed daemons<br/>unload the ones renamed to disabled]
  I --> J[Kick the daemon launchd would coalesce]
  J --> K[Prune worktrees whose PR merged]
  K --> L{Any hook failed?}
  L -- yes --> L1[Red. Your alert command runs once]
  L -- no --> M[Green. Your recovery command runs if a failure preceded it]
```

## License

MIT

# gangplank

Hands-off, reliable deploys to the Mac that runs your agents. Merge it, and your machine is running it.

gangplank turns a GitHub self-hosted runner into a deploy-only agent for one Mac. A merge to main lands on the machine in seconds, through one door, never by force. No open port, no tunnel, no secret to rotate.

Built for machines that run long-lived things: OpenClaw, Claude Code loops, daemons, dashboards.

## What gangplank adds

The runner and git do the transport. gangplank adds what neither does:

- **The gate.** The runner will run any job it is handed; the gate refuses all but one named workflow on one named branch, fails closed if it cannot verify, and makes no network calls. That is what makes a self-hosted runner safe on a machine that holds secrets.
- **Refuse instead of force.** Divergence, a failed fetch, or a tree that cannot fast-forward stops the deploy and says why. Never a reset.
- **Park, do not re-apply.** Your uncommitted edits on the box are set aside under a named stash and left there. A deploy never edits your working files.
- **Self-heal from a stranded checkout.** A box left on a branch that has since squash-merged is put back on main and deployed.
- **Install only what changed.** Dependencies are reinstalled only in the packages whose manifest moved in this deploy.
- **Daemons ship with their code.** A new or changed launchd definition is loaded on the deploy that carries it; one renamed to disabled is unloaded.
- **Restarts launchd would drop.** Rapid file changes get coalesced into one event and one daemon loses; gangplank kicks it explicitly.
- **Parallel-session cleanup that cannot delete live work.** A worktree goes only when its PR merged, its tree is clean, and no session holds it.
- **Failure-only alerting.** One Slack message when a deploy fails, resolved when the next one succeeds. Nothing on success.

## License

MIT

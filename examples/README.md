# What CCyclops writes

One made-up week of output, in the exact shapes the prompts in [`commands/`](../commands) ask for. All names, repos and numbers are invented. Open this folder as an Obsidian vault to see the wikilinks resolve and the copy button on the standup block.

| File | Written by | When |
|---|---|---|
| [`Daily/2026-10-20.md`](Workflows/Daily/2026-10-20.md) | **standup** (everything above 🌙) and **wrapdown** (the 🌙 Wrap-up) | weekday mornings and evenings |
| [`Reviews/shop-PR482.md`](Workflows/Reviews/shop-PR482.md) | **pr-queue** — only findings with a concrete failure scenario, no nitpicks | before the standup, skipped while the PR is unchanged |
| [`Tickets/1234 Discount codes at checkout.md`](Workflows/Tickets/1234%20Discount%20codes%20at%20checkout.md) | the **session hooks** append the work log; standup and wrapdown keep `status:` current; *What it is* is yours | at the end of every Claude Code session on the ticket's branch |
| [`Weekly/2026-W43.md`](Workflows/Weekly/2026-W43.md) | **/weekly** | when you run it, or on a schedule (`JOB_WEEKLY="fri 16:00"`) |

The pieces feed each other: the ticket's work log is what the standup reads for "Yesterday", the standup links the pre-review note, the wrap-up measures the day against the standup's "Today", and the weekly rollup reads the dailies.

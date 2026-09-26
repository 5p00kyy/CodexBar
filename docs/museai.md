---
summary: "Muse provider: muse.ai Free, Power, and Maximum weekly usage from browser session cookies."
read_when:
  - Configuring muse.ai usage tracking
  - Debugging muse.ai session cookies or server-action discovery
---

# Muse Provider

[Muse](https://muse.ai) is Meta's personal agent. Its Free, Power, and Maximum plans share one weekly token allowance.
This is separate from [Muse Code](muse.md), which reads the `muse` CLI login.

Sign in at `muse.ai` in a supported browser, or choose **Manual** and paste a Cookie header. CodexBar shows the weekly
percentage, reset time, plan, tokens left (paid plans), renewal date, and any additional (top-up) tokens.

muse.ai has no usage API. `museai.js` posts the settings dialog's Next.js server action (`fetchSubscriptionAction`) with
`Sec-Fetch-*` headers, since muse.ai rejects other server-action requests with 403. The action ID changes on each deploy,
so the plugin stores the last working ID. On `404 Server action not found.` it loads the signed-in page's chunks, finds
the lazy module that preloads settings, and reads the new ID from that module's chunk. A redirect to `auth.muse.ai` or a
403 means that session expired, and the plugin tries the next browser session before reporting it.

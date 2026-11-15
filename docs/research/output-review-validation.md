# Output review validation — TES-266

Status: human observation not performed. Implementation and automated checks are separate evidence.

Use one real repository and three actual tasks: compare named prototype alternatives, inspect a tiny UI/copy change, and repeat an interaction from a stated starting state. Run three to five real sessions, including a real request, a recorded result, an intentionally stale preview and a failed check. Preserve the failing/stale evidence; never label seeded examples as production measurements.

Open Needs you, identify the next blocker, inspect the exact result, record a correction, accept the recorded result, then inspect Finish summary. Product acceptance must not approve a tool, publication or cleanup. Native results open only supported explicit build paths; this implementation does not launch arbitrary simulators. Paths outside the worktree, including external DerivedData builds, are unsupported and must be moved/revealed through an explicit supported path.

Record the actual build/revision, task/result versions, participant role, observation date and supported-case denominator. Do not enter private session transcripts or credentials.

| Observation | Actual value |
| --- | --- |
| Build/revision | Unmeasured |
| Time to find blocker | Unmeasured |
| Time to open correct result | Unmeasured |
| Repeated setup | Unmeasured |
| Clarification rounds | Unmeasured |
| Cleanup doubt | Unmeasured |
| Participant recognises stale preview | Unmeasured |
| Participant recognises failed check | Unmeasured |

TES-266 passes only after both recognition observations are recorded from an actual participant. The 90% launch target and five-second blocker target are unmeasured. Test fixtures and agent inspection do not satisfy these user measures.

Source identity records bounded repository content, including tracked differences and untracked file bytes. Ignored build output and running pages remain unverified. A matching source check is not proof of preview/build identity or visual correctness.

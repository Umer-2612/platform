# Interview Platform: MVP Plan

One interview room, three modes, one team building it. This doc is the plan: architecture, features, repos. No implementation here.

> Reference repos are in `Desktop/Projects` and `Desktop/Ideas`. We copy/adapt code from them; none of them are the final codebase.

---

## Current status

Update this section whenever something actually ships, it's the one place anyone (including future you) can check without re-reading every repo.

| Repo | Status |
|---|---|
| `core-api` | Auth flow built and tested (login, invite-accept, me, logout). Company/User/Invitation only, jobs/candidates/sessions removed on purpose, coming back one at a time. Linked to Infisical. |
| `web-frontend` | Login, invite-accept, and a minimal dashboard built. Not yet linked to Infisical or verified live against `core-api` in a browser. |
| `platform` | This doc plus `bootstrap.sh` and `repos.manifest` (clones the other repos, links each to Infisical). No docker-compose yet, neither service is containerized right now, both just run via `npm run dev` against the shared Supabase database. |
| `video-service`, `sandbox-orchestrator`, `judge-service`, `collab-service` | Not started. |

Database: one shared Supabase Postgres instance across every repo, not local Docker Postgres. `core-api` connects via `DATABASE_URL` (pooled) and `DIRECT_URL` (direct, for migrations), both live in Infisical.

---

## 1. The idea

- Not three separate tools: **one interview room with switchable modes**.
- Hiring manager and candidate join one video call.
- Video stays live the whole time. The hiring manager switches the shared panel:
  - Video only
  - DSA round (collaborative code editor)
  - VSCode test (real IDE with live preview)
- One link, one room, everything inside it.

```mermaid
flowchart LR
    HM["Hiring Manager"] -->|joins| Room[("Interview Room")]
    C["Candidate"] -->|joins| Room
    Room --> V["🎥 Video (always on)"]
    Room --> P{"Switchable panel"}
    P --> D["DSA Editor"]
    P --> S["VSCode Sandbox + Preview"]
```

---

## 2. Architecture at a glance

```mermaid
flowchart TB
    FE["web-frontend (Next.js)"]

    FE --> Core["core-api\nauth, orgs, jobs, candidates, sessions"]
    FE --> Video["video-service\nLiveKit call"]
    FE --> Collab["collab-service\nlive code sync (Yjs)"]
    FE --> Sandbox["sandbox-orchestrator\nper-session containers"]

    Sandbox --> Judge["judge-service\nruns and grades code"]

    Core --> DB[("Postgres, single database")]
    Judge --> DB
```

- **One Postgres database.** Each service owns its own tables; nobody else writes to them directly.
- **Services split by what they actually need**, not by convenience:
  - `core-api`: plain CRUD
  - `video-service`: media server (very different from CRUD)
  - `sandbox-orchestrator` / `judge-service`: runs untrusted code, needs isolation
  - `collab-service`: long-lived WebSocket connections

---

## 3. Features: have vs. need

### ✅ Resume parsing (already built)
- `Interview-Platform-Backend/src/shared/utils/resume-extractor.ts`
- Real parser, not an LLM call: `pdf-parse` plus regex section detection for name, email, phone, skills, experience.
- **Action:** lift as-is into `core-api`.

### 🟡 Video call (mostly built, needs wiring)
- Backend: `interview-rooms.service.ts` already issues real LiveKit tokens.
- Frontend: `InterviewRoom.tsx` already exists, built but never connected to a page.
- **Gap:** current flow is solo AI Q&A, not a live 2-person call.
- **Action:** wire the existing component to a real session page; extend tokens for 2 named participants.

### 🟢 VSCode-in-browser + live preview (almost solved)
- `open-web-agent/src/lib/docker.ts`: per session, spins up
  - a `code-server` container (the editor)
  - a "runner" container that serves the candidate's dev server as a live preview
- `open-web-agent/src/components/workspace/WorkspaceClient.tsx`: tab UI (VSCode / Preview), same "switchable panel" idea, already built.
- The one tricky part (iframe-blocking headers) is already solved there.
- **Gap:** it clones a GitHub repo and runs an AI agent; we don't need either.
- **Action:** reuse the two-container pattern and the tab UI, swap in a test template instead of a GitHub clone.
- **Note:** this is the same mechanism the DSA round needs. One system, two templates.

### 🔴 DSA round (editor exists, judge doesn't)
- Collaborative editor: `Codeinterview`'s Yjs sync (`yjs-server.js` / `useYjs.js`), real-time, works.
- Data model: `Codeinterview`'s Prisma schema (`Room`, `Participant`, `Question`, `Schedule`) is a clean base.
- **No real judge exists in any cloned repo:**
  - `Codeinterview` runs code with `new Function()` in-process. Not sandboxed, and escapable.
  - `CodingInterviewPlatform` has no server-side execution at all (browser-only).
- **Action:** self-host **Judge0** or **Piston**. Build fresh, run inside the sandbox container from the feature above.

### ⬜ Not used
- `CodingInterviewPlatform`: thinner duplicate, reference only
- `vscode` (storezhang fork): cosmetic wrapper on the same `code-server` image `open-web-agent` already uses correctly
- `realtime-transcribe`: fine tech, just post-MVP (live transcript add-on)

---

## 4. User flow

```mermaid
sequenceDiagram
    participant HM as Hiring Manager
    participant Core as core-api
    participant Cand as Candidate
    participant Vid as video-service

    HM->>Core: Post job, invite candidate
    Core-->>Cand: Sends interview link
    Cand->>Vid: Opens link, joins call
    HM->>Vid: Joins call
    HM->>Core: Switches mode (DSA / VSCode)
    Core-->>Cand: Panel switches (video keeps running)
    Cand->>Core: Codes, runs, submits
    HM->>Core: Ends interview, fills scorecard
```

- **Candidate never provisions anything.** Panel changes follow the hiring manager automatically.
- **No candidate signup.** The invite link carries a signed session token.

---

## 5. Repos (7 total)

| # | Repo | Purpose |
|---|---|---|
| 1 | `platform` | Local dev bootstrap: `bootstrap.sh` clones the other repos and links each to Infisical, this doc |
| 2 | `core-api` | Auth today (orgs, jobs, candidates, resume parsing, session state come back one at a time) |
| 3 | `video-service` | LiveKit token issuance and the video call |
| 4 | `sandbox-orchestrator` | Per-session containers, powers both VSCode test and DSA round |
| 5 | `judge-service` | Runs and grades submitted code (Judge0/Piston) |
| 6 | `collab-service` | Live collaborative code editor (Yjs) |
| 7 | `web-frontend` | The actual app: video panel, editor panel, preview panel |

No separate "orchestrator" service. `core-api` owns session state directly at this size.

---

## 6. Data

- **One Postgres database, hosted on Supabase.** Shared across every repo. Each service owns its
  own tables; others go through its API, not direct SQL.
- `core-api` today: `Company`, `User`, `Invitation` (see its `API.md` for the exact relationships).
  Jobs/candidates/interview-sessions/scorecards come back one at a time, each with its schema
  decided deliberately when it's actually needed, not lifted wholesale from a reference repo.

---

## 7. Onboarding (no setup calls needed)

```bash
git clone https://github.com/Umer-2612/platform.git
cd platform
./bootstrap.sh          # installs the Infisical CLI if needed, logs you in, clones every
                         # service into services/<name>, links each to the Infisical project
```

Then, per service you actually want to run: `cd services/<name> && npm install && npm run dev`
(check that service's own README, commands differ slightly by stack). No docker-compose
aggregation yet, that's worth building once a service actually needs to run in a container
(the sandbox/judge services will, `core-api`/`web-frontend` don't).

Secrets live in Infisical (not files people pass around); inviting a new collaborator means
adding them to the GitHub repos and the Infisical project, not sharing credentials.

---

## 8. Build order

1. **`core-api`**: auth plus org/job/candidate CRUD plus session state. The product spine.
2. **`video-service`**: wire up the existing `InterviewRoom.tsx`. Fastest demoable 1:1 call.
3. **`sandbox-orchestrator`**: port `open-web-agent`'s container pattern. Gets VSCode-in-browser working.
4. **`collab-service` + `judge-service`**: port the Yjs layer, stand up Judge0/Piston. Gets the DSA round working.
5. **Wire panel switching in `web-frontend`**. Turns 3 features into 1 product.

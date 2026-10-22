# HomeListen engineering instructions

## Start here
Read README.md, SETUP.md and the files relevant to the requested task. Inspect actual implementation before relying on documentation. Preserve the project's pinned SDKs, lockfiles, architecture and deployment workflow. Keep changes scoped to the user's request.

## Skills
Selected official upstream skills are checked into .agents/skills/ with their supporting files. Read only the relevant SKILL.md and references. Sources, immutable revisions and licenses are recorded in .agents/skills-sources.json and .agents/licenses/.
- Flutter UI/architecture: flutter-apply-architecture-best-practices, flutter-fix-layout-issues.
- Mobile tests: flutter-add-widget-test, flutter-add-integration-test.
- Dart diagnosis/testing: dart-run-static-analysis, dart-fix-runtime-errors, dart-resolve-package-conflicts, dart-add-unit-test.
- Firebase: firebase-auth-basics, firebase-firestore, firebase-security-rules-auditor, firestore-rules-creation.
- Worker/API/deployment tooling: workers-best-practices, wrangler.

Upstream examples are guidance, not permission for unrelated migrations, model selection, new paid services or deployment. Keep test-only driver instrumentation out of production entry points. Prefer existing integration-test setup and verify examples against installed SDKs. Do not replace existing anonymous identity or membership design with generic login examples. Use the local Firestore emulator and demo-homelisten for rules validation.

## Specialist delegation
Role prompts are in .claude/agents/; Claude Code can discover these definitions. In Codex or another agent host, explicitly delegate using the same role file as task instructions. Merely checking in these files does not register tools, install an MCP server or start agents.
- mobile-engineer: Flutter UI, state, permissions and native lifecycle.
- audio-webrtc-reviewer: capture, detector, peers and reconnection review.
- firebase-security-reviewer: rules, API permissions and access isolation.
- cloudflare-backend-engineer: Worker, web viewer, push and retries.
- qa-release-reviewer: independent regression/build review.

Use specialists when the scope benefits; do not launch all roles for a small edit. Give each implementation task disjoint file ownership, acceptance criteria and a target revision. Run read-only reviews concurrently when useful, then integrate sequentially. For firestore.rules edits, delegate a writable task using .agents/upstream/firebase/agents/firestore-rules-author.md and its referenced creation skill; map its tool names to available host tools. If delegation is unavailable, use the same workflow in the main agent and disclose that no independent review ran.

## HomeListen invariants
- Capture starts locally with visible microphone state and a local Stop action; push/restart must not silently start sharing.
- Guardian creates no live audio track. Preserve platform capabilities: Android supports Live + Guardian; iPhone home mode currently supports Guardian.
- Stop cancels capture, peers and reconnect attempts. Revocation and expired access must block future signaling and alerts.
- Preserve invitation expiry, role checks, session/generation checks, TOTP replay prevention and throttling.
- Keep detection local. Audio recording is opt-in per alert and receiving-device-only; never save clips on the home phone or upload them. Preserve active-live-session authorization, Stop, revocation, expiry and recording-gap handling.
- Never commit signing keys, service-account JSON, push private keys, TURN secrets or real household data. Redact sensitive logs.
- Test Worker authorization separately from Firestore rules; privileged server credentials bypass client rules.

## Validation
Use existing scripts from the relevant package and required CI checks:
- Flutter: flutter analyze; flutter test; relevant Android/iOS build when tooling exists.
- Rules: npm ci; npm run test:rules (local emulator; Java requirements in README).
- Backend: npm --prefix backend ci; npm --prefix backend run check; npm --prefix backend test.
- Viewer: npm --prefix viewer ci; npm --prefix viewer run check; npm --prefix viewer test.
- Packaging: npm --prefix viewer run build, then npm --prefix backend run build (deployment dry run).
For a documentation/agent-only change, validate file structure, references, frontmatter and git diff rather than rebuilding the apps.

Report what changed, commands/results, and remaining device/environment gaps. Automated checks do not prove locked-screen capture, push delivery, network handover or sound-detection accuracy. Do not present this product as an emergency alarm. Preserve existing authorization boundaries for publishing and live deployments.

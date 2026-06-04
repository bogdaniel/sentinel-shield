# Threat Model (Lite)

A practical, time-boxed threat model. Aim for one to two pages. Use it for new
features and significant changes. STRIDE provides the prompts; do not over-engineer.

| Field | Value |
| --- | --- |
| System / feature | |
| Author | |
| Date | |
| Version | |

## 1. What are we building?

One paragraph. What does it do, who uses it, what data does it handle?

## 2. Diagram (text is fine)

```
[user] --HTTPS--> [web app] --> [api] --> [database]
                                   |
                                   +--> [third-party payment provider]
```

Mark trust boundaries (where data crosses from less-trusted to more-trusted).

## 3. Assets

- What data/funds/capabilities matter here?
- Classification: PII / payment / auth / audit / public.

## 4. Threats (STRIDE prompts)

For each component or data flow, ask:

| Category | Prompt | Threat here? | Mitigation |
| --- | --- | --- | --- |
| **S**poofing | Can an actor impersonate another? | | |
| **T**ampering | Can data be modified in transit/at rest? | | |
| **R**epudiation | Can an action be denied later? (audit logs) | | |
| **I**nformation disclosure | Can data leak? | | |
| **D**enial of service | Can it be made unavailable? | | |
| **E**levation of privilege | Can an actor gain more rights? | | |

## 5. Top risks and actions

| # | Risk | Severity | Owner | Action / status |
| --- | --- | --- | --- | --- |
| 1 | | | | |

## 6. Decisions and assumptions

- Assumptions we are relying on (e.g. "the API is only reachable inside the VPC").
- Decisions made and why.

## 7. Follow-ups

- [ ] Items to track. Link to issues. High-severity items block release per
      [`../RELEASE-GATES.md`](../RELEASE-GATES.md).

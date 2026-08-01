# Quieter permission prompts in the setup wizard

## Motivation
The setup wizard asks for the same directory-access permission on every
page; users report prompt fatigue and click through without reading.

## Proposed behavior
- Ask once, cache the grant for the wizard session, and show a single
  summary of granted permissions on the final page.

## Acceptance criteria
- [ ] One prompt per permission per wizard session.
- [ ] Final page lists every cached grant.

## Source
Operator conversation, 2026-07-30.

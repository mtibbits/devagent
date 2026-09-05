<!-- tests/fixtures/potholes-migration-register.md — #613 fixture register: a SOURCE
     register in the pre-#613 mixed-token shape. Consumed by
     tests/potholes-postcondition.bats (the register file contract) and by the
     Issue-613 migration's --selftest (routing, fork token, retoken, cross-section
     family). Project names are synthesised (zzq*); the CRLF trap is synthesised
     at test time because the plugin's .gitattributes normalises this file to LF. -->

# Pothole register (fixture)

## Bash exit-status & control flow
- a bare seed-owner line (Issue-7).
- a merged line carrying two projects (Issue-7; zzqother Issue-2).
- a fork-tracker line (Issue-Fork-9).
- a mis-tokened line whose citation sits inside a parenthetical (two sites: a and b — Issue-11).

## Docs / edit-neighborhood hygiene
- a line that names ZzqOther in its body (zzqother Issue-3).
- a family member: a guard that greps a message LITERAL dies when the message is reworded → export the string (Issue-12).
- a lower-case project spelling (ZZQOTHER Issue-4).

## Sweeps / fix-at-source / sibling sites
- a family member: a guard that greps a message literal dies when the message is reworded -> export the string as a constant (Issue-13).
- a line kept as a singleton (Issue-14).

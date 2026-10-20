# Resist Forever

## 1.0.2

- Updated resistance calculations for current WoW Forever beta behavior.
- Partial resistance is now shown in 10% damage steps instead of Classic's 25/50/75% buckets.
- Updated level-based spell miss calculations and removed the old unavoidable 1% miss assumption.
- Spell miss is now labelled as base spell miss because enemy spell-hit bonuses are unknown.
- Updated target-level calculations to use the current Forever model.

## 1.0.1

- Spell miss against you uses the classic player (PvP) table: 13% at +3 levels, then +7% per further level. A level-10 caster into a level-22 player is about 76% miss, not 100%.
- Pets and other non-player defenders still use the PvE table (17% at +3, then +11% per level).
- The same resistance tooltip now appears on the pet character panel.

## 1.0.0

- Shows partial-resist chances and spell miss on the character panel resistance tooltips.

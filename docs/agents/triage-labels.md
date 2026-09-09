# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those roles to the actual
label strings used in this repo's issue tracker. We use the defaults: each label string equals its
role name.

| Label in mattpocock/skills | Label in our tracker | Meaning                                  |
| -------------------------- | -------------------- | ---------------------------------------- |
| `needs-triage`             | `needs-triage`       | Maintainer needs to evaluate this issue  |
| `needs-info`               | `needs-info`         | Waiting on reporter for more information |
| `ready-for-agent`          | `ready-for-agent`    | Fully specified, ready for an AFK agent  |
| `ready-for-human`          | `ready-for-human`    | Requires human implementation            |
| `wontfix`                  | `wontfix`            | Will not be actioned                     |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the corresponding label
string from this table.

**All five exist on `yakir12/Fromage.jl`** as of 2026-09-09. `wontfix` was already there, carrying
GitHub's own description ("This will not be worked on") rather than the table's wording — harmless,
since the skills match on the label string, not the description. The other four were created with:

```sh
gh label create needs-triage    -c fbca04 -d "Maintainer needs to evaluate this issue"
gh label create needs-info      -c d876e3 -d "Waiting on reporter for more information"
gh label create ready-for-agent -c 0e8a16 -d "Fully specified, ready for an AFK agent"
gh label create ready-for-human -c 1d76db -d "Requires human implementation"
```

Kept here because `/triage` only ever *applies* labels — it never creates them, so a missing label
surfaces as a failed `gh issue edit --add-label`, not as a label appearing. If the vocabulary in the
right-hand column is ever changed, the new strings have to be created on the tracker the same way.

Edit the right-hand column to match whatever vocabulary you actually use.

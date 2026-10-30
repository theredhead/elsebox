# Swift readability

Inherit the shared rules from the parent workspace. In this project:

- Every class, including private helper classes, needs a `///` purpose comment
  directly above its attributes/declaration. Explain why it exists and what it
  owns; do not merely restate its name.
- Separate methods and computed members with one blank line. Group stored
  properties and method bodies into short, coherent paragraphs.
- Prefer short, clearly named methods. A class approaching roughly 200 code lines
  deserves a responsibility review; this is guidance, not a numeric pass/fail rule.
  Do not hide size with extensions or create forwarding types solely to meet a quota.
- Extract objects that own a coherent decision, resource lifetime, UI component or
  workflow. Keep their inputs/callbacks narrow and document their ownership boundary.
- `scripts/check-readability.py` checks purpose-comment presence and declaration
  whitespace. Its `--fix` mode inserts whitespace only. The quality of the prose
  and the design still requires human/model review.
- After adding/removing/moving Swift sources, run
  `python3 scripts/sync-xcode-sources.py`; then run `./scripts/check.sh` and
  `./build.sh`. Keep the real Xcode groups aligned with the physical folders.

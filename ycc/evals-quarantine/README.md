# Quarantined eval cases

Known-failing cases kept out of the default `scripts/eval.sh` run. Empty for now:
the three YAN-1114 should-trigger cases (`compare-rate-limit-options`,
`validate-research-before-planning`, `structure-go-packages`) passed again and were
promoted to `ycc/evals/trigger/` under YAN-1146.

To quarantine a case, move its directory here, tag it `quarantine`, and list it in
`ycc/evals/README.md`. Run quarantined cases explicitly:

```bash
claude plugin eval ./ycc --eval-dir evals-quarantine --runs 1 --ablation none --no-publish --max-cost-usd 1
```

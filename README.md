# VegaLoad functional tests

Happy-path functional tests for VegaLoad releases. They run on a GKE lab through Harness, and the same commands are the examples in the docs.

The plan is [docs/test-plan.md](docs/test-plan.md).

The product stays in [vegaload/vegaload](https://github.com/vegaload/vegaload). This repo holds the lab, the cases, and the pipelines.

## Run the suite

`scripts/run-suite.sh` runs every case in `cases/`. `scripts/run-case.sh` runs one. The pipelines call these same scripts. They need `python3` from the standard library, an env file of `NAME=value` lines, and the path to a VegaLoad binary. Run them from the repo root.

```
scripts/run-suite.sh --env targets.env --out out --vegaload /path/to/vegaload
scripts/run-case.sh --case cases/HP-HTTP-01.yaml --env targets.env --out out --vegaload /path/to/vegaload
```

Without `--priority`, only P0 cases run. `--priority all` also runs P1. `--area NAME` and `--case ID` select a subset.

Each case prints one line, `PASS <id>` or `FAIL <id>: ...`. A case that needs a report that is not there yet prints `SKIP <id>: needs <file>`. The last line is `N passed, M failed, K skipped`. The suite exits 1 when a P0 case fails or is skipped.

A run writes `out/<id>.json`, `out/<id>.html`, `out/<id>.log`, `out/<id>.stdout`, and `out/<id>.exit`. The suite also writes `out/results.tsv` and `out/suite.junit.xml`.

Licence: Apache-2.0.

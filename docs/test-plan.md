# VegaLoad functional test plan

Release check. The suite is automated, it covers the whole product, and every case is a happy path. A passing case is also a documentation example: the command in the case is the command a reader can copy.

The build under test is one pinned binary, the commit that will be tagged for release. The suite does not follow a moving branch during a run.

## 1. What a pass is

A case passes when all of these are true:

- `vegaload` exits 0. Exit 0 is not enough on its own: `vegaload run` exits 0 when every request fails. The validator reads `failed` and `error_rate` from the JSON summary.
- The JSON summary from `-out` exists.
- `total` is greater than 0.
- `failed` is 0.
- `error_rate` is 0.
- When the scenario calls `check`, every check passed. The JSON summary has no `check_rate` field. The validator computes it from `checks`: add `passes`, add `fails`, and require `passes / (passes + fails)` to be 1. A run with no `checks` skips this rule.
- Every threshold named in the case passes.
- A password or token does not appear in the JSON summary, the HTML report, or the console log. The validator greps those outputs for the value. `-secret-env` is only for a scenario file. With `-target` and `-protocol` the command refuses it. A protocol-direct case passes the password with `-opt password_env=NAME`.
- The HTML report file exists, unless the case passes `-no-report`.

CI always passes `-no-open` and `-yes` (or `-allow-target` for the lab host). Lab addresses are inside the cluster, so they are not treated as localhost.

Durations stay short: 5 virtual users for 10 seconds, unless a case says otherwise. That keeps the whole suite inside one pipeline run.

## 2. Where this runs

One GKE cluster. One namespace, `vegaload-lab`. A Harness delegate in that cluster runs the pipeline, so targets are cluster DNS names and nothing has to be exposed on the public internet.

Images live in Artifact Registry. Passwords live in Secret Manager and reach the test pod as environment variables. A scenario reads one with `-secret-env`. A protocol-direct case reads one with `-opt password_env=NAME`.

The VegaLoad step uses the Helm chart in the product repo (`charts/vegaload`) or the same Job shape as `examples/k8s/job.yaml`. The image is `ghcr.io/vegaload/vegaload` at the pinned tag, or an image built from that commit and pushed to Artifact Registry when the tag does not exist yet.

### Lab services

`lab-up` creates these and waits until each is ready. It writes a `targets.env` that the run stage substitutes into every case.

| Name | What it is | Address in the namespace | Used by |
|---|---|---|---|
| sample-app | `examples/sample-app` from the product repo. That directory has no Dockerfile. The lab image runs the binary with `-addr :8080 -grpc-addr :9090`, because the defaults listen on 127.0.0.1 | `sample-app:8080` HTTP/1.1, HTTP/2 (h2c), and WebSocket; `sample-app:9090` gRPC | HTTP, WebSocket, gRPC, OpenAPI, HAR |
| mqtt | Mosquitto, anonymous inside the namespace | `mqtt:1883` | MQTT |
| kafka | Single-node Kafka. `lab-up` creates a topic named `orders` | `kafka:9092` | Kafka |
| postgres | PostgreSQL 16. Database `vegaload`, user from Secret Manager | `postgres:5432` | PostgreSQL |
| mysql | MySQL 8. Database `vegaload`, user from Secret Manager | `mysql:3306` | MySQL |
| redis | Redis 7 | `redis:6379` | Redis |
| rabbitmq | RabbitMQ 4. User from Secret Manager. vhost `/` | `rabbitmq:5672` | RabbitMQ |
| echo | TCP echo on 7000 and UDP echo on 7001 | `echo:7000`, `echo:7001` | TCP, UDP |
| ftp | vsftpd, one local user, password from Secret Manager. Passive ports 21100 to 21110. `pasv_address` is not set, so the server announces the pod address | `ftp:21` | FTP |
| sftp | OpenSSH, one user, password login, SFTP subsystem. The user is not chrooted. The host key is a Secret. `lab-up` writes its SHA256 fingerprint to `SFTP_HOST_KEY` | `sftp:22` | SFTP |

`GET /health` and `GET /widgets` on sample-app return success with no injected errors. `POST /widgets` and gRPC `CreateWidget` inject failures on purpose. Happy-path cases call the read endpoints. The fault-injection endpoints stay out of this suite so a green run means VegaLoad worked.

gRPC `Health/Check` with an empty body works on today's sample-app as a protocol-direct call. `grpc.call` in a scenario sends JSON and needs server reflection, which sample-app does not offer yet. Before the script case is turned on, the lab image of sample-app enables reflection. Until that image is built, the gRPC gate is the protocol-direct health call.

RabbitMQ is in the pinned release. It shipped in VegaLoad v0.7.0. HP-RMQ-01 sets `username` because the broker rejects `guest` from a remote host.

## 3. Pipelines

Three Harness pipelines. The pipelines run in order: create the lab, run the cases, validate the reports. They share one pipeline input, `vegaload_ref`, the git tag or commit of the binary.

Org, project, and the GCP and Kubernetes connectors are set in Harness. The pipeline YAML in this repo is the source. Harness runs that YAML.

### `vegaload-lab-up` — create

1. Select the GKE cluster and namespace `vegaload-lab`.
2. Build sample-app from `vegaload_ref` and push it to Artifact Registry.
3. Apply `targets/` and wait until every Deployment is ready.
4. Create the Kafka topic `orders` and the PostgreSQL and MySQL database `vegaload` if they are missing.
5. Publish `targets.env` as a pipeline output.

Running it again updates the lab. It does not delete data it does not own.

### `vegaload-functional` — run

1. Read `targets.env`.
2. Install the VegaLoad binary for `vegaload_ref`.
3. Run the cases in `cases/`. Areas run in parallel. Cases inside one area run one after another, so two cases do not share a queue, topic, or table by accident.
4. Each case writes `out/<id>.json`, `out/<id>.html` unless it passes `-no-report`, and `out/<id>.junit.xml` when it asked for JUnit. The runner adds `-out out/<id>.json` and, for a case that makes an HTML report, `-report out/<id>.html`. VegaLoad's default HTML name is `vegaload-report-<timestamp>.html`, and `scripts/validate-report.sh` looks for `out/<id>.html`. Every flag, including `-out` and `-report`, comes before the scenario file. A flag after the file is ignored, and the JSON summary is never written.

A case file is a small YAML document:

```yaml
id: HP-HTTP-01
area: http
doc: "Run a load test, no scenario file needed"
argv:
  - run
  - -target
  - http://sample-app:8080/health
  - -protocol
  - http1
  - -vus
  - "5"
  - -duration
  - 10s
  - -yes
  - -no-open
  - -out
  - out/HP-HTTP-01.json
  - -report
  - out/HP-HTTP-01.html
expect:
  exit: 0
  total_min: 1
  failed: 0
```

The runner substitutes service hostnames from `targets.env`. It does not invent flags.

### `vegaload-functional` — validate

This is the last stage of the same pipeline.

1. For each case, run `scripts/validate-report.sh` on `out/<id>.json` and that case's exit code.
2. Fail the stage when the script reports a broken rule. The log names the case id. A non-zero exit is one rule. Exit 0 with `failed` greater than 0 is another.
3. Upload `out/` to a GCS bucket, one prefix per `vegaload_ref` and pipeline execution.
4. Publish the JUnit files so the Harness execution shows one test per case.

`vegaload mcp eval` is one case. Its own suite is the check. The stage also requires that command to exit 0.

### Docs stay tied to the cases

`docs/examples.md` in this repo lists every case id, the command, and the README heading it supports. A check script fails when a case id is missing from that list, or when the command in the case file and the command in `docs/examples.md` differ. That list is what gets copied into the product README after the suite is green, so the docs and the tests describe the same run.

## 4. Cases

P0 cases gate the release. P1 cases are the second language and the extra shapes. They run in the same pipeline. A P1 failure does not block the release tag, and it is written down in the release notes. A P0 failure blocks the tag.

Commands below omit `-yes`, `-no-open`, `-out out/<id>.json`, and `-report out/<id>.html`. The runner adds them. A case that passes `-no-report` does not get `-report`. VegaLoad's default HTML name is `vegaload-report-<timestamp>.html`, and the validator looks for `out/<id>.html`. `${...}` comes from `targets.env`.

### CLI

| ID | P | What a reader sees | Command | Pass |
|---|---|---|---|---|
| HP-CLI-01 | P0 | The binary name and version | `vegaload version` | Exit 0, stdout starts with `vegaload ` |
| HP-CLI-02 | P0 | The command list | `vegaload help` | Exit 0, stdout contains `run`, `validate`, `new`, `diagnose`, `compare`, `doctor`, `import`, `mcp` |

### Protocol list

| ID | P | What a reader sees | Command | Pass |
|---|---|---|---|---|
| HP-PROTO-01 | P0 | The list of protocols as JSON | `vegaload protocols -output json` | Exit 0. stdout is one JSON object. `schema_version` is 1. `protocols` has 14 entries, and their `name` values are http1 http2 grpc websocket mqtt kafka postgres mysql redis rabbitmq ftp sftp tcp udp |
| HP-PROTO-02 | P0 | A wrong protocol name is refused and the list is shown | `vegaload run -target http://sample-app:8080/health -protocol bogus -vus 1 -duration 1s -yes -no-open` | Exit 2. Output contains `unknown -protocol "bogus"` and `Supported protocols:` and all 14 names. No JSON summary is expected |

### HTTP and load shapes

Target is `GET ${SAMPLE_HTTP}/health` unless the row says otherwise. Protocol `http1`.

| ID | P | What a reader sees | Command shape | Pass |
|---|---|---|---|---|
| HP-HTTP-01 | P0 | A fixed number of users against an HTTP URL | `-protocol http1 -vus 5 -duration 10s` | Section 1 |
| HP-HTTP-02 | P0 | The same URL over HTTP/2 | `-protocol http2` on `${SAMPLE_HTTP}/health` | Section 1 |
| HP-HTTP-03 | P0 | A read of a JSON list | `-protocol http1` on `${SAMPLE_HTTP}/widgets` | Section 1 |
| HP-SHAPE-01 | P0 | Users climb and fall | `-executor ramp -stages 2:5s,5:5s,0:5s` | Section 1 |
| HP-SHAPE-02 | P0 | Users jump between levels | `-executor step -stages 2:5s,5:5s` | Section 1 |
| HP-SHAPE-03 | P0 | A fixed arrival rate | `-executor constant-arrival-rate -rate 20 -duration 10s -max-vus 10` | Section 1, `total` at least 100 |

### WebSocket and gRPC

| ID | P | What a reader sees | Command shape | Pass |
|---|---|---|---|---|
| HP-WS-01 | P0 | Send one message and read the echo | `-protocol websocket -target ${SAMPLE_WS}/ws/echo -body hello -vus 5 -duration 10s` | Section 1 |
| HP-GRPC-01 | P0 | A health check, empty protobuf body | `-protocol grpc -target ${SAMPLE_GRPC} -method /grpc.health.v1.Health/Check -vus 5 -duration 10s` | Section 1 |
| HP-GRPC-02 | P1 | The same health check from a scenario, JSON in and out | `grpc.call` against a lab image that has reflection on | Section 1, every check passed |

HP-WS-01 sends a body. The suite does not run a handshake-only WebSocket flood. Those exhaust local ports and make the next case fail for a reason that is outside VegaLoad.

### TCP and UDP

| ID | P | What a reader sees | Command shape | Pass |
|---|---|---|---|---|
| HP-TCP-01 | P0 | Send bytes and read them back | `-protocol tcp -target tcp://echo:7000 -body ping -opt until=pong` with an echo that replies `pong` | Section 1 |
| HP-UDP-01 | P0 | Send one datagram and read the reply | `-protocol udp -target udp://echo:7001 -body ping -opt reply=true` | Section 1 |

The echo program is part of `targets/`. Its reply is fixed, so `expect` can match it.

### MQTT and Kafka

| ID | P | What a reader sees | Command shape | Pass |
|---|---|---|---|---|
| HP-MQTT-01 | P0 | Publish a message | `-protocol mqtt -target mqtt://mqtt:1883 -opt topic=vegaload/lab -body hello` | Section 1 |
| HP-MQTT-02 | P0 | Publish and read the same message back | `-opt mode=roundtrip -opt topic=vegaload/lab -body 'hello {id}'` | Section 1 |
| HP-KAFKA-01 | P0 | Write one record to `orders` | `-protocol kafka -target kafka://kafka:9092 -opt topic=orders -body hello` | Section 1 |
| HP-KAFKA-02 | P0 | Write a record and read it back | `-opt mode=roundtrip -opt topic=orders -body hello` | Section 1 |

### Databases and brokers

Each case uses the lab user. PostgreSQL, MySQL, RabbitMQ, FTP and SFTP take the password from the environment through `-opt password_env=NAME`. These cases are protocol-direct, so they do not pass `-secret-env`. The validator greps the output for the password.

Reads are the default. A case that writes passes `-opt allow_writes=true` and uses a name that starts with `vegaload_lab_`. Each call deletes its own file. A call cut off by the end of the run can leave one. PostgreSQL and MySQL happy paths are a single `SELECT 1`. Redis is `PING`. RabbitMQ is a roundtrip on `amq.topic` with routing key `vegaload.lab`, which needs no queue left behind.

| ID | P | Protocol | Command shape | Pass |
|---|---|---|---|---|
| HP-PG-01 | P0 | postgres | `-target postgres://postgres:5432/vegaload -body 'select 1' -opt username=... -opt password_env=PGPASSWORD` | Section 1, and the password is absent from the output |
| HP-MY-01 | P0 | mysql | `-target mysql://mysql:3306/vegaload -body 'select 1' -opt username=... -opt password_env=MYSQL_PASSWORD` | Same |
| HP-REDIS-01 | P0 | redis | `-target redis://redis:6379 -body PING` | Section 1. The JSON summary does not include the reply text, so the case does not look for `PONG` |
| HP-RMQ-01 | P0 | rabbitmq | `-target amqp://rabbitmq:5672 -opt mode=roundtrip -opt exchange=amq.topic -opt routing_key=vegaload.lab -opt username=... -body hello -opt password_env=RABBITMQ_PASSWORD` | Section 1. `guest` cannot log in from a remote host, so the case sets `username` |

### FTP and SFTP

Plain FTP only. The user is chrooted, so the path starts at `/`. SFTP is not chrooted, so the path is relative to the home directory. The host key is `${SFTP_HOST_KEY}`.

| ID | P | Protocol | Command shape | Pass |
|---|---|---|---|---|
| HP-FTP-01 | P0 | ftp | `-target ftp://ftp:21 -opt username=${FTP_USER} -opt password_env=FTP_PASSWORD -opt mode=roundtrip -opt allow_writes=true -opt path=/vegaload_lab_rt-{id}.bin -opt size=4096 -vus 5 -duration 10s` | Section 1. `protocols` has ftp. `measures` has `upload_time`, `download_time`, `delete_time`. The password is absent from the output |
| HP-SFTP-01 | P0 | sftp | `-target sftp://sftp:22 -opt username=${SFTP_USER} -opt password_env=SFTP_PASSWORD -opt host_key=${SFTP_HOST_KEY} -opt mode=roundtrip -opt allow_writes=true -opt path=vegaload_lab_rt-{id}.bin -opt size=4096 -vus 5 -duration 10s` | Same, with sftp |

P1 adds one scenario file per protocol, matching the examples already in the product repo (`postgres-orders`, `mysql-orders`, `redis-cache`, `rabbitmq-orders`, and `kafka-orders.vl.js`). JavaScript and Python are both copied where the product repo has both. `kafka-orders` is JavaScript only. Those scenarios are copied into `scenarios/` and pointed at the lab addresses. They keep the same checks.

### Scenarios, checks, steps, data

| ID | P | What a reader sees | Command shape | Pass |
|---|---|---|---|---|
| HP-SCN-01 | P0 | A JavaScript scenario with `http.get` and `check` | `vegaload run -vus 5 -duration 10s scenarios/health.vl.js` | Section 1, every check passed |
| HP-SCN-02 | P0 | The same scenario in Python | `scenarios/health.py` | Same |
| HP-SCN-03 | P0 | A named step shows up in the summary | `step("health", ...)` inside HP-SCN-01 | JSON `steps` contains `health` |
| HP-DATA-01 | P0 | A row from a CSV and a secret from the environment | `-data data/users.csv -secret-env LAB_TOKEN` and a scenario that reads `data.users.next()` and `env.LAB_TOKEN`, then sends GET | Section 1, `LAB_TOKEN`'s value is absent from the output. The scenario does not POST `/widgets`: that endpoint fails about 3% of the time on purpose |
| HP-VAL-01 | P0 | One user, once, before a real run | `vegaload validate scenarios/health.vl.js` | Exit 0 |
| HP-DATA-02 | P0 | A data file fills one query parameter per call | `-target postgres://postgres:5432/vegaload -protocol postgres -data data/ids.csv -opt username=${PG_USER} -opt password_env=PGPASSWORD -body 'select $1::int as id' -opt 'args=[{data.ids.id:int}]' -vus 5 -duration 10s` | Section 1. `data_files` has `ids.csv` with 5 rows. The password is absent from the output |

`data/ids.csv` has five rows, `id` 1 through 5. `select $1::int` needs no table. `-secret-env` stays for scenario files. This case passes the password with `-opt password_env=PGPASSWORD`.

`scenarios/health.vl.js` calls `GET ${SAMPLE_HTTP}/health` and checks status 200. The Python file does the same. Both files are the ones the docs will show.

### Reports, thresholds, compare, diagnose

These use the JSON from HP-HTTP-01, or a fresh run of that same command.

| ID | P | What a reader sees | Command shape | Pass |
|---|---|---|---|---|
| HP-THR-01 | P0 | A run gated on its own numbers | HP-HTTP-01 plus `-threshold "error_rate < 1%" -threshold "p95 < 5s" -junit out/HP-THR-01.junit.xml` | Exit 0, both thresholds pass, JUnit file has those two cases |
| HP-CMP-01 | P0 | A second run compared with a baseline | Save HP-HTTP-01's JSON as the baseline, run the same command again with `-baseline` and `-max-regression 50` | Exit 0 |
| HP-DIAG-01 | P0 | A plain explanation of a healthy report | `vegaload diagnose out/HP-HTTP-01.json` | Exit 0, and the text contains `no failed requests`. A healthy report still prints `failure rate:`, so the case does not search for the word `failure` |
| HP-JSON-01 | P0 | A machine-readable summary on stdout | `-output json` on a 10s health run | Exit 0, stdout is one JSON object with `total` and `failed` |
| HP-THR-02 | P0 | A threshold on one protocol | HP-HTTP-01 plus `-threshold 'p95{protocol="http1"} < 5s'` | Section 1. `thresholds` has that one entry with `passed` true. `thresholds_passed` is true |
| HP-RES-01 | P1 | The report has a section per protocol | No new run. Read `out/HP-HTTP-01.json` | `protocols` has an http1 entry with `total` above 0 |
| HP-CMP-02 | P1 | compare shows each protocol | Run the HP-HTTP-01 command again into `out/HP-CMP-02-run.json`, then `compare -p95-ratio 2 -error-rate-delta 0.01 out/HP-HTTP-01.json out/HP-CMP-02-run.json` | Exit 0. Output contains a line `protocols` and a line that starts with `http1` |

The baseline allowance is 50 percent because two short runs on a shared cluster are not identical. The case checks that compare accepts a healthy pair. Tightening the number is a later tuning, after a week of runs.

### Import, OpenAPI, doctor, MCP, Kubernetes

| ID | P | What a reader sees | Command shape | Pass |
|---|---|---|---|---|
| HP-HAR-01 | P0 | A scenario from a browser recording | A checked-in HAR of `GET /health` and `GET /widgets`. `vegaload import har recordings/widgets.har -o scenarios/from-har.vl.js`, then `vegaload validate` on that file against the lab | Validate exits 0 |
| HP-OAPI-01 | P0 | A scenario and a runbook from an OpenAPI document | `vegaload new -from-openapi examples/sample-app/openapi.json lab-widgets` with the server URL rewritten to the lab, then validate a GET from the runbook | The command writes both files and validate exits 0. The generated scenario POSTs `/widgets`, which fails about 3% of the time on purpose, so the case does not validate that file unchanged |
| HP-DOC-01 | P0 | Doctor can see the CLI and the lab | `vegaload doctor -target http://sample-app:8080/health` | Exit 0 |
| HP-MCP-01 | P0 | The MCP tools match the CLI | `vegaload mcp eval` | Exit 0 |
| HP-MCP-02 | P1 | One tool call runs a real test | A small stdio client calls `run_test` with the HP-HTTP-01 arguments and `yes: true` | The tool result has `failed` 0 |
| HP-K8S-01 | P0 | A load test as a Kubernetes Job | Helm install of `charts/vegaload` into `vegaload-lab`, target `http://sample-app:8080/health`, protocol `http1`, 5 users, 10 seconds, threshold `error_rate < 1%` | The Job completes, the pod exits 0 |

`vegaload init` registers editor files on the machine where it runs. A pipeline pod has no editor. The release gate uses doctor and `mcp eval` for the agent path. `init` stays a step in the install doc, tried once on a laptop before release.

## 5. Keeping the suite current

A user-facing command, flag, protocol, or scenario global gets a case in section 4 in the same pull request as the feature. The row names the README heading it supports. A feature without a row is not covered by this suite.

| Feature | Case id | README heading | Covered |
|---|---|---|---|
| FTP and FTPS | HP-FTP-01 | Test an FTP server | yes |
| SFTP | HP-SFTP-01 | Test an SFTP server | yes |
| vegaload protocols | HP-PROTO-01, HP-PROTO-02 | Supported protocols | yes |
| Per-protocol results | HP-RES-01, HP-CMP-02 | Gate a run on pass/fail thresholds | yes |
| Protocol thresholds | HP-THR-02 | Gate a run on pass/fail thresholds | yes |
| -data with -protocol | HP-DATA-02 | Data files with -protocol | yes |

## 6. Release gate

The release tag is cut when:

1. `vegaload_ref` is the commit being tagged.
2. `vegaload-lab-up` is green on that commit.
3. Every P0 case is green on that commit.
4. `docs/examples.md` matches the case files.
5. The release notes list any P1 case that was not run.

P0 is 40 cases: CLI 2, protocol list 2, HTTP and shapes 6, WebSocket 1, gRPC 1, TCP 1, UDP 1, MQTT 2, Kafka 2, PostgreSQL 1, MySQL 1, Redis 1, RabbitMQ 1, FTP 1, SFTP 1, scenarios and data 6, reports 5, import and OpenAPI 2, doctor 1, MCP eval 1, Helm 1.

## 7. Scheduled runs

The same pipeline can run on a schedule against a tagged release. Failures there mean the lab or the release regressed. New cases follow the same YAML shape and the same pass rules.

This suite covers happy paths only. Refused logins, missing flags, thresholds that fail the run, and the fault-injection endpoints on sample-app belong in a separate suite.

## 8. Repo layout

```
docs/test-plan.md          this plan
docs/examples.md           one block per case, copied toward the product README
cases/<id>.yaml            the command and the pass rules
scenarios/                 health.vl.js, health.py, and the protocol examples
recordings/widgets.har     the HAR import input
data/users.csv             the data-file input
data/ids.csv               five ids for a protocol-direct query
targets/                   Deployments and Services for the lab
pipelines/                 Harness pipeline YAML
scripts/run-case.sh        substitute targets.env, run vegaload, record the exit code
scripts/validate-report.sh check section 1 against out/<id>.json
scripts/validate-output.sh check a command that has no run summary
```

`scripts/run-case.sh` and `scripts/validate-report.sh` are the only runners. The pipeline calls them. A person can call them the same way on a laptop pointed at a port-forward, which is how a case is debugged when the pipeline goes red.

`scripts/validate-report.sh` applies section 1 to one case:

```
scripts/validate-report.sh --id HP-HTTP-01 --json out/HP-HTTP-01.json --exit 0
scripts/validate-report.sh --id HP-DIAG-01 --diagnose out/HP-DIAG-01.txt --exit 0 --no-report
scripts/validate-report.sh --id HP-PG-01 --json out/HP-PG-01.json --exit 0 --secret "$PGPASSWORD"
```

`--exit 0` is required and is not a pass by itself. The JSON summary must have `total` at least `--total-min` (default 1), `failed` 0, and `error_rate` 0. There is no `check_rate` field. When `checks` is present, the script adds `passes` and `fails` and requires that ratio to be 1. `--require-checks` fails a summary that has no checks. `--require-protocol NAME` requires that protocol with `total` above 0. `--require-measure NAME` requires a measure with `count` above 0. `--require-data-file NAME:ROWS` requires that data file and row count. `--require-threshold NAME` requires a thresholds entry with that exact name and `passed` true. `--require-thresholds-passed` requires `thresholds_passed` true. `--secret` is grepped as a fixed string in the JSON summary, the HTML report, and `--log` when that log is passed. The HTML report must exist unless `--no-report` is set. `--diagnose` requires the text `no failed requests`. A healthy diagnosis still prints `failure rate:`, and the script does not search for the word `failure`.

`scripts/validate-output.sh` checks a command that does not write a run summary. `--exit` is the command's exit code and must equal `--want-exit`. `--contains` is a fixed string in `--stdout`. When `--log` is passed, `--contains` searches that file instead, which holds stdout and stderr together. `--protocols-json` still reads `--stdout`, and requires `schema_version` 1 and the 14 protocol names in order.

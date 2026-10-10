# VegaLoad functional test plan

Release check. The suite is automated, it covers the whole product, and every case is a happy path. A passing case is also a documentation example: the command in the case is the command a reader can copy.

The build under test is one pinned binary, the commit that will be tagged for release. The suite does not follow a moving branch during a run.

## 1. What a pass is

A case passes when all of these are true:

- `vegaload` exits 0.
- The JSON summary from `-out` exists.
- `total` is greater than 0.
- `failed` is 0.
- `error_rate` is 0.
- When the scenario calls `check`, `check_rate` is 1.
- Every threshold named in the case passes.
- A value passed with `-secret-env` does not appear in the JSON summary, the HTML report, or the console log.
- The HTML report file exists, unless the case passes `-no-report`.

CI always passes `-no-open` and `-yes` (or `-allow-target` for the lab host). Lab addresses are inside the cluster, so they are not treated as localhost.

Durations stay short: 5 virtual users for 10 seconds, unless a case says otherwise. That keeps the whole suite inside one pipeline run.

## 2. Where this runs

One GKE cluster. One namespace, `vegaload-lab`. A Harness delegate in that cluster runs the pipeline, so targets are cluster DNS names and nothing has to be exposed on the public internet.

Images live in Artifact Registry. Passwords live in Secret Manager and reach the test pod as environment variables. Scenarios read them with `-secret-env`.

The VegaLoad step uses the Helm chart in the product repo (`charts/vegaload`) or the same Job shape as `examples/k8s/job.yaml`. The image is `ghcr.io/vegaload/vegaload` at the pinned tag, or an image built from that commit and pushed to Artifact Registry when the tag does not exist yet.

### Lab services

`lab-up` creates these and waits until each is ready. It writes a `targets.env` that the run stage substitutes into every case.

| Name | What it is | Address in the namespace | Used by |
|---|---|---|---|
| sample-app | `examples/sample-app` from the product repo, built into Artifact Registry | `sample-app:8080` HTTP/1.1, HTTP/2 (h2c), and WebSocket; `sample-app:9090` gRPC | HTTP, WebSocket, gRPC, OpenAPI, HAR |
| mqtt | Mosquitto, anonymous inside the namespace | `mqtt:1883` | MQTT |
| kafka | Single-node Kafka. `lab-up` creates a topic named `orders` | `kafka:9092` | Kafka |
| postgres | PostgreSQL 16. Database `vegaload`, user from Secret Manager | `postgres:5432` | PostgreSQL |
| mysql | MySQL 8. Database `vegaload`, user from Secret Manager | `mysql:3306` | MySQL |
| redis | Redis 7 | `redis:6379` | Redis |
| rabbitmq | RabbitMQ 4. User from Secret Manager. vhost `/` | `rabbitmq:5672` | RabbitMQ |
| echo | TCP echo on 7000 and UDP echo on 7001 | `echo:7000`, `echo:7001` | TCP, UDP |

`GET /health` and `GET /widgets` on sample-app return success with no injected errors. `POST /widgets` and gRPC `CreateWidget` inject failures on purpose. Happy-path cases call the read endpoints. The fault-injection endpoints stay out of this suite so a green run means VegaLoad worked.

gRPC `Health/Check` with an empty body works on today's sample-app as a protocol-direct call. `grpc.call` in a scenario sends JSON and needs server reflection, which sample-app does not offer yet. Before the script case is turned on, the lab image of sample-app enables reflection. Until that image is built, the gRPC gate is the protocol-direct health call.

RabbitMQ is part of this plan when the driver is in the pinned release commit.

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
4. Each case writes `out/<id>.json` and, when it asked for one, `out/<id>.html` and `out/<id>.junit.xml`.

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
expect:
  exit: 0
  total_min: 1
  failed: 0
```

The runner substitutes service hostnames from `targets.env`. It does not invent flags.

### `vegaload-functional` — validate

This is the last stage of the same pipeline.

1. For each `out/<id>.json`, check the pass rules in section 1 against that case's `expect` block.
2. Fail the stage on the first missing file, a non-zero exit, or a broken rule. The log names the case id.
3. Upload `out/` to a GCS bucket, one prefix per `vegaload_ref` and pipeline execution.
4. Publish the JUnit files so the Harness execution shows one test per case.

`vegaload mcp eval` is one case. Its own suite is the check. The stage also requires that command to exit 0.

### Docs stay tied to the cases

`docs/examples.md` in this repo lists every case id, the command, and the README heading it supports. A check script fails when a case id is missing from that list, or when the command in the case file and the command in `docs/examples.md` differ. That list is what gets copied into the product README after the suite is green, so the docs and the tests describe the same run.

## 4. Cases

P0 cases gate the release. P1 cases are the second language and the extra shapes. They run in the same pipeline. A P1 failure does not block the release tag, and it is written down in the release notes. A P0 failure blocks the tag.

Commands below omit `-yes`, `-no-open`, and `-out out/<id>.json`. The runner adds them. `${...}` comes from `targets.env`.

### CLI

| ID | P | What a reader sees | Command | Pass |
|---|---|---|---|---|
| HP-CLI-01 | P0 | The binary name and version | `vegaload version` | Exit 0, stdout starts with `vegaload ` |
| HP-CLI-02 | P0 | The command list | `vegaload help` | Exit 0, stdout contains `run`, `validate`, `new`, `diagnose`, `compare`, `doctor`, `import`, `mcp` |

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
| HP-GRPC-02 | P1 | The same health check from a scenario, JSON in and out | `grpc.call` against a lab image that has reflection on | `check_rate` is 1 |

HP-WS-01 sends a body. The suite does not run a handshake-only WebSocket flood. Those exhaust local ports and make the next case fail for a reason that is outside VegaLoad.

### TCP and UDP

| ID | P | What a reader sees | Command shape | Pass |
|---|---|---|---|---|
| HP-TCP-01 | P0 | Send bytes and read them back | `-protocol tcp -target tcp://echo:7000 -body ping -opt until=pong` with an echo that replies `pong` | Section 1 |
| HP-UDP-01 | P0 | Send one datagram and read the reply | `-protocol udp -target udp://echo:7001 -body ping -opt read=4` | Section 1 |

The echo program is part of `targets/`. Its reply is fixed, so `expect` can match it.

### MQTT and Kafka

| ID | P | What a reader sees | Command shape | Pass |
|---|---|---|---|---|
| HP-MQTT-01 | P0 | Publish a message | `-protocol mqtt -target mqtt://mqtt:1883 -opt topic=vegaload/lab -body hello` | Section 1 |
| HP-MQTT-02 | P0 | Publish and read the same message back | `-opt mode=roundtrip -opt topic=vegaload/lab -body hello` | Section 1 |
| HP-KAFKA-01 | P0 | Write one record to `orders` | `-protocol kafka -target kafka://kafka:9092 -opt topic=orders -body hello` | Section 1 |
| HP-KAFKA-02 | P0 | Write a record and read it back | `-opt mode=roundtrip -opt topic=orders -body hello` | Section 1 |

### Databases and brokers

Each case uses the lab user. The password comes from the environment through `-opt password_env=...` and `-secret-env`. The summary must not contain the password.

Reads are the default. A case that writes passes `-opt allow_writes=true` and uses a name that starts with `vegaload_lab_`, then deletes that name before it finishes. PostgreSQL and MySQL happy paths are a single `SELECT 1`. Redis is `PING`. RabbitMQ is a roundtrip on `amq.topic` with routing key `vegaload.lab`, which needs no queue left behind.

| ID | P | Protocol | Command shape | Pass |
|---|---|---|---|---|
| HP-PG-01 | P0 | postgres | `-target postgres://postgres:5432/vegaload -body 'select 1' -opt username=... -opt password_env=PGPASSWORD` | Section 1, and the password is absent from the output |
| HP-MY-01 | P0 | mysql | `-target mysql://mysql:3306/vegaload -body 'select 1' -opt username=... -opt password_env=MYSQL_PASSWORD` | Same |
| HP-REDIS-01 | P0 | redis | `-target redis://redis:6379 -body PING` | Section 1, reply shows `PONG` in the iteration output |
| HP-RMQ-01 | P0 | rabbitmq | `-target amqp://rabbitmq:5672 -opt mode=roundtrip -opt exchange=amq.topic -opt routing_key=vegaload.lab -body hello -opt password_env=RABBITMQ_PASSWORD` | Section 1 |

P1 adds one scenario file per protocol, JavaScript and Python, matching the examples already in the product repo (`postgres-orders`, `mysql-orders`, `redis-cache`, `kafka-orders`, `rabbitmq-orders`). Those scenarios are copied into `scenarios/` and pointed at the lab addresses. They keep the same checks.

### Scenarios, checks, steps, data

| ID | P | What a reader sees | Command shape | Pass |
|---|---|---|---|---|
| HP-SCN-01 | P0 | A JavaScript scenario with `http.get` and `check` | `vegaload run -vus 5 -duration 10s scenarios/health.vl.js` | Section 1, `check_rate` is 1 |
| HP-SCN-02 | P0 | The same scenario in Python | `scenarios/health.py` | Same |
| HP-SCN-03 | P0 | A named step shows up in the summary | `step("health", ...)` inside HP-SCN-01 | JSON `steps` contains `health` |
| HP-DATA-01 | P0 | A row from a CSV and a secret from the environment | `-data data/users.csv -secret-env LAB_TOKEN` and a scenario that reads `data.users.next()` and `env.LAB_TOKEN` | Section 1, `LAB_TOKEN`'s value is absent from the output |
| HP-VAL-01 | P0 | One user, once, before a real run | `vegaload validate scenarios/health.vl.js` | Exit 0 |

`scenarios/health.vl.js` calls `GET ${SAMPLE_HTTP}/health` and checks status 200. The Python file does the same. Both files are the ones the docs will show.

### Reports, thresholds, compare, diagnose

These use the JSON from HP-HTTP-01, or a fresh run of that same command.

| ID | P | What a reader sees | Command shape | Pass |
|---|---|---|---|---|
| HP-THR-01 | P0 | A run gated on its own numbers | HP-HTTP-01 plus `-threshold "error_rate < 1%" -threshold "p95 < 5s" -junit out/HP-THR-01.junit.xml` | Exit 0, both thresholds pass, JUnit file has those two cases |
| HP-CMP-01 | P0 | A second run compared with a baseline | Save HP-HTTP-01's JSON as the baseline, run the same command again with `-baseline` and `-max-regression 50` | Exit 0 |
| HP-DIAG-01 | P0 | A plain explanation of a healthy report | `vegaload diagnose out/HP-HTTP-01.json` | Exit 0, and the text does not describe an error-rate failure |
| HP-JSON-01 | P0 | A machine-readable summary on stdout | `-output json` on a 10s health run | Exit 0, stdout is one JSON object with `total` and `failed` |

The baseline allowance is 50 percent because two short runs on a shared cluster are not identical. The case checks that compare accepts a healthy pair. Tightening the number is a later tuning, after a week of runs.

### Import, OpenAPI, doctor, MCP, Kubernetes

| ID | P | What a reader sees | Command shape | Pass |
|---|---|---|---|---|
| HP-HAR-01 | P0 | A scenario from a browser recording | A checked-in HAR of `GET /health` and `GET /widgets`. `vegaload import har recordings/widgets.har -out scenarios/from-har.vl.js`, then `vegaload validate` on that file against the lab | Validate exits 0 |
| HP-OAPI-01 | P0 | A scenario and a runbook from an OpenAPI document | `vegaload new -from-openapi examples/sample-app/openapi.json lab-widgets` with the server URL rewritten to the lab, then validate the generated scenario | The command writes both files and validate exits 0. The generated file is edited only to point at the lab host, which the generator already tells the reader to do |
| HP-DOC-01 | P0 | Doctor can see the CLI and the lab | `vegaload doctor -target http://sample-app:8080/health` | Exit 0 |
| HP-MCP-01 | P0 | The MCP tools match the CLI | `vegaload mcp eval` | Exit 0 |
| HP-MCP-02 | P1 | One tool call runs a real test | A small stdio client calls `run_test` with the HP-HTTP-01 arguments and `yes: true` | The tool result has `failed` 0 |
| HP-K8S-01 | P0 | A load test as a Kubernetes Job | Helm install of `charts/vegaload` into `vegaload-lab`, target `http://sample-app:8080/health`, protocol `http1`, 5 users, 10 seconds, threshold `error_rate < 1%` | The Job completes, the pod exits 0 |

`vegaload init` registers editor files on the machine where it runs. A pipeline pod has no editor. The release gate uses doctor and `mcp eval` for the agent path. `init` stays a step in the install doc, tried once on a laptop before release.

## 5. Keeping the suite current

A user-facing command, flag, protocol, or scenario global gets a case in section 4 in the same pull request as the feature. The row names the README heading it supports. A feature without a row is not covered by this suite.

## 6. Release gate

The release tag is cut when:

1. `vegaload_ref` is the commit being tagged.
2. `vegaload-lab-up` is green on that commit.
3. Every P0 case is green on that commit.
4. `docs/examples.md` matches the case files.
5. The release notes list any P1 case that was not run.

P0 is 34 cases: CLI 2, HTTP and shapes 6, WebSocket 1, gRPC 1, TCP 1, UDP 1, MQTT 2, Kafka 2, PostgreSQL 1, MySQL 1, Redis 1, RabbitMQ 1, scenarios and data 5, reports 4, import and OpenAPI 2, doctor 1, MCP eval 1, Helm 1.

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
targets/                   Deployments and Services for the lab
pipelines/                 Harness pipeline YAML
scripts/run-case.sh        substitute targets.env, run vegaload, record the exit code
scripts/validate-report.sh check section 1 against out/<id>.json
```

`scripts/run-case.sh` and `scripts/validate-report.sh` are the only runners. The pipeline calls them. A person can call them the same way on a laptop pointed at a port-forward, which is how a case is debugged when the pipeline goes red.

# Unison Cloud BYOC Provider Research (AWS, GCP, IBM, Azure, and portability options)

Date: 2026-03-04

## Executive summary

Today, BYOC is AWS-first by implementation, not just by examples.

- Blob storage is wired through an `awsConfig` block and currently assumes an S3-compatible API.
- State storage is currently DynamoDB-only in documented architecture and Terraform.

The shortest path to non-AWS BYOC is:

1. Keep the existing S3-compatible blob contract.
2. Introduce a pluggable State backend abstraction in Nimbus.
3. Start with a DynamoDB-compatible State endpoint (for portability speed), then add first-class native backends.

Most practical first target after AWS: **Google Cloud**.
Reason: official XML interoperability and HMAC flow for Cloud Storage align with the current blob model; state is still the major lift.

## What the current BYOC code says

Repository evidence:

- Architecture doc says transactional storage currently supports only DynamoDB.
  - `docs/architecture/README.md`
- Architecture doc says blob stores with S3-compatible API are supported.
  - `docs/architecture/README.md`
- Runtime config templates use `blobFetcher.awsConfig`, `userBlobFetcher.awsConfig`, and `dynamo`.
  - `ec2/config.json.template`
  - `eks/unison.tf`
  - `docker/nimbus-config-example.json`
- Terraform provisions AWS S3 + AWS DynamoDB and grants DynamoDB actions including conditional and transactional operations.
  - `ec2/s3.tf`, `ec2/dynamo.tf`
  - `eks/s3.tf`, `eks/dynamo.tf`

Practical implication:

- Blobs are already conceptually portable if an S3-compatible endpoint is available.
- State is tightly coupled to DynamoDB semantics and APIs.

## Required backend capabilities (from current Terraform/runtime)

From current IAM/action usage and config shape, State backend behavior appears to require:

- Key-value operations: `GetItem`, `PutItem`, `UpdateItem`, `DeleteItem`
- Conditional writes/checks: `ConditionCheckItem`
- Batch operations: `BatchGetItem`, `BatchWriteItem`
- Scans/queries: `Scan` and in some paths `Query`
- Transactional write support in EKS policy: `TransactWriteItems`

This means a replacement State backend must either:

- Support equivalent conditional + atomic semantics, or
- Accept behavior changes and add compensating logic/retries in Nimbus.

## Provider-by-provider analysis

## 1) AWS (current supported baseline)

Pros:

- Native fit for current code and Terraform (S3 + DynamoDB already implemented).
- Lowest engineering risk and fastest path to reliable production.
- Existing docs and operational path are already AWS-centric.

Cons:

- Vendor concentration for both Blobs and State.
- Cost tuning can become complex at scale.

What is needed for BYOC on AWS:

- No architectural change required.
- Mainly hardening/ops improvements (least-privilege IAM tightening, durability/lifecycle, observability, backup/restore policies).

## 2) Google Cloud

Pros:

- Cloud Storage offers XML API interoperability with S3-oriented tools/libraries.
- HMAC key flow is explicitly documented for XML API auth.
- Strong global infra and good Kubernetes ergonomics for BYOC-style deployments.

Cons:

- State backend is the hard part: no drop-in managed DynamoDB service.
- Native alternatives have semantic differences:
  - Bigtable transactions are single-row scoped.
  - Firestore transactions have different model/limits and retry behavior.
- Terraform stack would need broad provider/resource replacement.

What is needed for BYOC on GCP:

- Blob path (moderate):
  - Parameterize blob endpoint/credentials in templates.
  - Use GCS XML endpoint + HMAC credentials where S3 compatibility is sufficient.
  - Validate multipart/object metadata behavior against Nimbus expectations.
- State path (large): choose one of:
  - Build a native GCP State backend adapter (Bigtable/Firestore/etc.), including semantic reconciliation.
  - Run a DynamoDB-compatible state service in GCP (operational overhead, but less Nimbus code churn).
- Infra path (large): rewrite Terraform modules for GCP networking, IAM, compute/k8s, and storage resources.

## 3) IBM Cloud

Pros:

- IBM Cloud Object Storage documents S3 API subset compatibility.
- Could reuse blob-side S3-compatible assumptions with adaptation/testing.

Cons:

- State backend still unsolved similarly to GCP/Azure.
- Smaller community footprint for this specific BYOC pattern compared with AWS/GCP/Azure.
- Likely more custom infrastructure module work and fewer ready-made runbooks.

What is needed for BYOC on IBM:

- Blob path (moderate): configure/test against IBM COS S3 subset.
- State path (large): native adapter effort or deploy a DynamoDB-compatible service.
- Infra path (large): new Terraform stack for IBM networking/compute/identity.

## 4) Azure

Why include Azure:

- Large enterprise footprint and strong regional/compliance coverage make it a common customer ask.

Pros:

- Mature cloud platform for compute/network/identity.
- Cosmos DB offers several APIs and global distribution options.

Cons:

- Current BYOC blob assumption is S3-compatible API; Azure Blob is documented as its own REST API surface.
- Cosmos DB API list does not include DynamoDB API.
- Therefore both Blobs and State likely require adapters/gateways or larger code changes.

Azure/Cosmos details relevant to Unison `State`:

- API surfaces: Cosmos DB documents support for NoSQL, MongoDB, PostgreSQL, Cassandra, Gremlin, and Table APIs (not DynamoDB API).
- Transaction boundaries: Cosmos DB transactional batch is scoped to a single logical partition key. This is important because DynamoDB-style transaction patterns in BYOC may span multiple keys/partitions unless explicitly redesigned.
- Throughput/cost unit: Cosmos centers billing on Request Units (RUs), with both provisioned and serverless modes.
- Pricing snapshot (East US 2, Azure Retail Prices API queried on 2026-03-03):
  - Provisioned: `100 RU/s` = `USD 0.008/hour`
  - Autoscale (metered RU): `100 RUs` = `USD 0.012/hour` (plus autoscale entry meter lines)
  - Serverless: `1M RUs` = `USD 0.25`
  - Data stored: `USD 0.25/GB-month` (non-free meter line)

What is needed for BYOC on Azure:

- Blob path (moderate-to-large):
  - Either add Azure Blob-native backend in Nimbus, or run an S3-compatible gateway/service.
- State path (large):
  - Add a Cosmos-backed State adapter (or other DB) with semantic mapping for conditional + transactional behavior.
- Infra path (large):
  - Terraform replacement across VNet, AKS/VMs, identity, and storage resources.

Inference from sources:

- The need for adapters on Azure is inferred from: current BYOC requiring S3-compatible blobs + DynamoDB-style state, while Azure docs emphasize Blob REST and Cosmos APIs that do not list DynamoDB.

## 5) Cross-cloud portability via compatibility layers (any provider)

This follows Stew’s note that S3 equivalents/self-hosted options exist.

Pros:

- Fastest route to multi-cloud without fully rewriting Nimbus storage/state internals first.
- Lets team keep AWS-style SDK paths while relocating infrastructure.

Cons:

- Adds operational burden (run/manage additional services).
- Compatibility gaps can appear under edge cases and performance extremes.
- You inherit reliability/SRE burden versus fully managed native services.

What is needed:

- For Blobs: an S3-compatible object store endpoint.
- For State: a DynamoDB-compatible API endpoint (self-hosted or managed alternative).
- Strong conformance and load testing for transaction/conditional semantics.

## IBM Cloud vs GCP: pricing and feature comparison for Unison BYOC

This section focuses on the parts that matter most for Unison BYOC:

- Blob store cost model (high read/write/API activity + egress sensitivity)
- State backend feasibility and semantics (conditional writes, atomicity, retries)
- Cost predictability for production operations

Pricing model comparison (as of 2026-03-03):

- Blob storage pricing model:
  - GCP Cloud Storage is metered by storage + operations + retrieval (for colder classes) + network egress.
  - IBM COS One-Rate is marketed as all-inclusive per-GB storage pricing with built-in API and egress allowances, then overage rates.
- GCP examples from official docs:
  - Cloud Storage Standard in `us-central1` is listed as `$0.000027397 / GiB-hour` (about `$0.02 / GiB-month`).
  - Class A / Class B operation pricing is separately billed (for example, Standard class entries shown in the operation table).
  - General internet data transfer pricing tiers are separately billed (example table starts at `$0.12 / GiB` tier).
  - Retrieval fees apply for Nearline/Coldline/Archive.
- IBM COS One-Rate details from IBM:
  - Described as one monthly rate per GB, with no separate retrieval/API/egress charges within allowances.
  - IBM lists overage examples: egress overage `USD 0.05/GB`, Class A overage `USD 0.005/1,000 ops`, Class B overage `USD 0.004/10,000 ops`.
  - IBM Cloud pricing page also references promotional pricing “as low as USD 10/TB/month” for One-Rate (promotional context).

State backend pricing and feasibility:

- GCP:
  - Bigtable has explicit pricing dimensions for compute nodes, storage, and network; examples show rates like `$0.65/node-hour` and `$0.17/GiB` in `us-central1` (example scenario values).
  - Firestore pricing is operation-centric (reads/writes/deletes + storage + egress), with documented free tier and location-based pricing.
  - Net effect: clearer path to estimate costs for a native non-Dynamo adapter, though semantics differ by chosen service.
- IBM:
  - IBM COS is straightforward for blob pricing modeling.
  - For State, reviewed IBM sources in this pass did not identify a managed DynamoDB-compatible service; IBM Cloudant is positioned as CouchDB-compatible JSON document DB (different model/semantics).
  - Net effect: state-side cost/effort depends heavily on chosen architecture (Cloudant adapter vs self-hosted Dynamo-compatible endpoint vs other DB), so uncertainty is higher early.

Feature comparison for Unison requirements:

- S3 compatibility (blob path):
  - GCP: XML API interoperability is documented; HMAC keys are supported specifically for XML API auth.
  - IBM: COS documents support for a subset of S3 API plus IAM/HMAC auth patterns.
- State semantics:
  - GCP Bigtable: atomic and conditional behavior is row-scoped (no multi-row atomic transactions).
  - GCP Firestore: multi-document transactions exist, but with read-before-write constraints and retry/contention behavior.
  - IBM Cloudant: strong availability and global distribution, but data model/transaction behavior differs materially from Dynamo-style state APIs.

Bottom line for IBM vs GCP:

- If blob-cost predictability for high-activity traffic is top priority, IBM COS One-Rate has a strong pricing shape.
- If you expect to build a native managed State backend soon, GCP currently offers a clearer set of managed database options and pricing surfaces for that engineering path.
- In both cases, BYOC still needs explicit State backend abstraction work in Nimbus; that remains the gating item for true non-AWS support.

## Detailed pricing comparison across AWS, GCP, Azure, IBM

Pricing data changes frequently. This section is a point-in-time comparison using list/public rates available from official sources as of 2026-03-03.

Method:

- Use one representative region per provider where a concrete rate was available in official docs/APIs.
- Compare the BYOC-relevant cost drivers separately:
  - Blob: storage + request operations + internet egress
  - State: database request/throughput/storage model
- Treat this as directional. Always validate against current calculator outputs for your target region.

Reference rate snapshot used:

- AWS:
  - S3 Standard requests: `PUT/COPY/POST/LIST = USD 0.005 per 1,000`, `GET/SELECT = USD 0.0004 per 1,000`.
  - DynamoDB on-demand: writes `USD 0.625/million WRUs`, reads `USD 0.125/million RRUs`, data storage `USD 0.25/GB-month`.
  - AWS example data transfer out to internet: first `10 TB/month = USD 0.09/GB`.
- GCP (`us-central1` examples from pricing docs):
  - Cloud Storage Standard: `USD 0.000027397/GiB-hour` (~`USD 0.02/GB-month`)
  - Class A ops: `USD 0.005 per 1,000`; Class B ops: `USD 0.0004 per 1,000`
  - Internet egress examples: first `1 TB = USD 0.12/GB`; next `9 TB = USD 0.11/GB`
  - Bigtable pricing example components include node-hour and storage rates (e.g. `USD 0.65/node-hour`, `USD 0.17/GiB`)
- Azure (`eastus2` via Retail Prices API):
  - Blob Hot LRS data stored: `USD 0.0184` down to `USD 0.016928/GB-month` (tier lines)
  - Blob operations: read `USD 0.004/10K`; write `USD 0.05/10K`; other ops `USD 0.004/10K`
  - Cosmos DB: provisioned `100 RU/s = USD 0.008/hour`; serverless `1M RUs = USD 0.25`; storage `USD 0.25/GB-month`
  - Bandwidth standard data transfer out meter lines include `USD 0.087 ... 0.04/GB` tiers
- IBM:
  - COS One-Rate: marketed as all-inclusive storage model with included API/egress allowances.
  - IBM One-Rate published overage examples: egress `USD 0.05/GB`, Class A `USD 0.005/1,000`, Class B `USD 0.004/10,000`.
  - Promotional headline on IBM pricing page references “as low as USD 10/TB-month”.
  - State backend equivalent (Cloudant or other) is not a DynamoDB-compatible drop-in and requires separate architecture/cost modeling.

Worked blob-cost example (directional only):

Assumptions:

- 1 TB hot object data stored
- 100M read requests/month
- 10M write requests/month
- 5 TB internet egress/month
- single region per cloud as noted above

Approximate monthly blob subtotal:

| Provider | Storage | Read ops | Write ops | Egress | Approx subtotal |
|---|---:|---:|---:|---:|---:|
| AWS (S3 + example egress rate) | `~$23` | `~$40` | `~$50` | `~$450` | `~$563` |
| GCP (Cloud Storage us-central1 examples) | `~$20` | `~$40` | `~$50` | `~$560` | `~$670` |
| Azure (Blob Hot LRS eastus2 + high egress tier) | `~$18-19` | `~$40` | `~$50` | `~$435` | `~$543-544` |
| IBM (One-Rate promotional + full overage assumption) | `~$10` | `~$40` | `~$50` | `~$250` | `~$350` |

Interpretation:

- Egress dominates cost quickly in all models.
- IBM can look materially cheaper for blob-heavy workloads if One-Rate allowances and overages align with your traffic profile.
- AWS/GCP/Azure blob costs are often in the same order of magnitude for similar access patterns; region and redundancy class choices can swing totals significantly.
- State-store economics are not directly apples-to-apples because each provider’s likely non-AWS state backend uses different units (RUs, node-hours, ops, partition constraints).

State-cost comparability caveat:

- AWS DynamoDB is request-unit priced and straightforward to model from current BYOC semantics.
- Azure Cosmos can be modeled in RUs, but required RUs depend on data model and partitioning choices.
- GCP Bigtable/Firestore pricing units differ significantly (node-hour vs per-op), so modeling depends on throughput/latency and access-shape decisions.
- IBM state choice is architectural first (Cloudant vs alternative), then pricing.

## Geography footprint and specialized hardware comparison

Geographic footprint snapshot:

- AWS: global infrastructure page reports `39 regions` and `123 Availability Zones`.
- GCP: locations page reports `42 cloud regions`, `127 zones`, and `202 network edge locations`.
- Azure: global infrastructure page reports `70+ regions` and `400+ highly secure datacenters`.
- IBM:
  - IBM Cloud VPC regional docs list `12 regions` (including multi-zone and single-campus regions).
  - IBM Cloudant product page describes service availability in `6 cloud regions`.

Specialized/exotic hardware highlights:

- AWS:
  - Accelerated instance families include FPGA (`F2`), Inferentia (`Inf2`), and Trainium (`Trn1`, `Trn2`) options.
- GCP:
  - GPU offerings include modern NVIDIA generations (region/series dependent).
  - TPU offerings (including Trillium generation documentation) provide a non-GPU accelerator path.
- Azure:
  - ND H100 v5 and ND MI300X v5 series provide high-end NVIDIA/AMD accelerator options.
- IBM:
  - IBM Cloud VPC and Kubernetes profiles include high-end accelerator options (including H100/H200 and Gaudi3 profiles).
  - IBM also offers IBM Power Virtual Server and LinuxONE-based options in IBM Cloud locations.

Implication for Unison BYOC:

- If “exotic hardware” for inference/training is a key requirement, AWS/GCP/Azure generally have broader mainstream accelerator ecosystems and region coverage.
- IBM can be attractive when you want specific hardware classes (Power, LinuxONE, Gaudi/H-series GPUs) and potentially lower/predictable blob economics, but with smaller geographic footprint and more bespoke platform choices.

## Comparative effort/risk matrix

Legend: Low / Medium / High / Very High

| Provider | Blob fit to current BYOC | State fit to current BYOC | Infra rewrite effort | Overall porting risk |
|---|---|---|---|---|
| AWS | Low effort | Low effort | Low | Low |
| GCP | Medium effort | High effort | High | High |
| IBM Cloud | Medium effort | High effort | High | High |
| Azure | Medium-High effort | High effort | High | High |
| Any cloud + compatibility layer | Medium effort | Medium-High effort | Medium-High | Medium-High |

## Recommended path

1. Keep AWS as production baseline for near-term reliability.
2. Make portability a deliberate engineering track:
   - Add a formal State backend interface in Nimbus.
   - Parameterize blob endpoint/auth cleanly in BYOC config templates.
3. Pilot **GCP** first:
   - Phase 1: S3-compatible blob path validation on GCS XML API.
   - Phase 2: choose state strategy (native adapter vs Dynamo-compatible service).
   - Phase 3: terraform module parity + reliability/perf validation.
4. Consider Azure and IBM after State abstraction is complete, since that is the dominant non-AWS effort.

## Concrete engineering backlog to enable true multi-cloud BYOC

- Introduce explicit backend interfaces:
  - `BlobStore` (S3-compatible and native adapters)
  - `StateStore` (DynamoDB and non-Dynamo adapters)
- Add capability/conformance test suite:
  - Conditional writes, idempotency, transaction atomicity, scan/query semantics
- Make config provider-neutral:
  - endpoint, auth type, retries/timeouts, consistency expectations
- Split Terraform into provider modules behind one input schema:
  - AWS module (existing)
  - GCP module
  - Azure module
  - IBM module
- Publish support policy:
  - “fully supported”, “tech preview”, “community supported” tiers

## Sources

Unison BYOC repo sources:

- https://github.com/unisoncomputing/byoc (repository root)
- Local files inspected in this repo:
  - `docs/architecture/README.md`
  - `ec2/config.json.template`
  - `docker/nimbus-config-example.json`
  - `ec2/dynamo.tf`
  - `ec2/s3.tf`
  - `eks/dynamo.tf`
  - `eks/s3.tf`
  - `eks/unison.tf`

Provider and platform docs:

- Unison BYOC page: https://www.unison.cloud/byoc/
- AWS S3 pricing: https://aws.amazon.com/s3/pricing/
- AWS DynamoDB pricing: https://aws.amazon.com/dynamodb/pricing/on-demand/
- Google Cloud Storage XML API overview: https://docs.cloud.google.com/storage/docs/xml-api/overview
- Google Cloud Storage interoperability: https://docs.cloud.google.com/storage/docs/interoperability
- Google Cloud Storage HMAC keys: https://docs.cloud.google.com/storage/docs/authentication/hmackeys
- Google Cloud Storage pricing: https://cloud.google.com/storage/pricing
- AWS DynamoDB `TransactWriteItems`: https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_TransactWriteItems.html
- AWS Global Infrastructure: https://aws.amazon.com/about-aws/global-infrastructure/
- AWS Accelerated Computing instances: https://aws.amazon.com/ec2/instance-types/accelerated-computing/
- AWS Media Services pricing examples (S3 storage example rate): https://aws.amazon.com/vi/media-services/pricing/
- Google Bigtable pricing: https://cloud.google.com/bigtable/pricing
- Google Bigtable routing/transaction semantics: https://cloud.google.com/bigtable/docs/routing
- Google Bigtable tables/views: https://docs.cloud.google.com/bigtable/docs/tables-and-views
- Google Cloud locations: https://cloud.google.com/about/locations
- Google Cloud GPU regions and zones: https://cloud.google.com/compute/docs/gpus/gpu-regions-zones
- Google Cloud TPU docs: https://cloud.google.com/tpu/docs
- Cloud Firestore pricing: https://firebase.google.com/docs/firestore/pricing
- Firebase Firestore transactions: https://firebase.google.com/docs/firestore/manage-data/transactions
- IBM Cloud Object Storage S3 API compatibility page: https://cloud.ibm.com/docs/cloud-object-storage?topic=cloud-object-storage-compatibility-api
- IBM Cloud Object Storage One-Rate announcement (pricing model details): https://www.ibm.com/new/announcements/get-predictable-low-cost-cloud-object-storage-for-active-workloads-with-the-one-rate-plan
- IBM Cloud pricing page: https://www.ibm.com/products/cloud/pricing
- IBM Cloudant product page: https://www.ibm.com/products/cloudant
- IBM Cloud VPC regions and locations: https://cloud.ibm.com/docs/vpc?topic=vpc-creating-a-vpc-in-a-region
- IBM Cloud location and data center docs: https://cloud.ibm.com/docs/overview?topic=overview-locations
- IBM Power Virtual Server: https://www.ibm.com/products/power-virtual-server
- IBM Cloud Kubernetes Service VPC profile list (GPU/accelerator profiles): https://cloud.ibm.com/docs/containers?topic=containers-vpc-profile-list
- Azure Storage REST API reference: https://learn.microsoft.com/en-us/rest/api/storageservices/
- Azure Cosmos DB documentation/API families: https://learn.microsoft.com/en-us/azure/cosmos-db/
- Azure Cosmos DB API for NoSQL transactional batch: https://learn.microsoft.com/en-us/azure/cosmos-db/nosql/transactional-batch
- Azure Cosmos DB billing model examples: https://learn.microsoft.com/en-us/azure/cosmos-db/understand-your-bill
- Azure Retail Prices API docs: https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices
- Azure Global Infrastructure: https://azure.microsoft.com/en-us/explore/global-infrastructure
- Azure ND H100 v5 VM sizes: https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/gpu-accelerated/ndh100v5-series
- Azure ND MI300X v5 VM sizes: https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/gpu-accelerated/ndmi300xv5-series
- ScyllaDB README (DynamoDB API compatibility context): https://raw.githubusercontent.com/scylladb/scylladb/master/README.md

# atp-indexer single-instance stack

Collapses the staking-dashboard **atp-indexer**'s per-env **ECS + Aurora + ALB** onto one
EC2 box running the indexer (this repo's own image) against a **local Postgres**, fronted by
**Caddy** (Caddy-direct TLS for testnet, or **CloudFront-front** for prod). This mirrors the
ignition-monorepo single-instance pattern — the two repos are decoupled and their
atp-indexers have **diverged** (this one additionally indexes `ATP_FACTORY_MATP`/`LATP` and
has the zombie/withdrawing provider features), so each repo runs **its own** indexer code.

The **frontend is unchanged** — it stays on S3+CloudFront (already ~free). This stack only
moves the expensive indexer.

## What it creates (own Terraform state)
- EC2 (default-VPC public subnet) + EIP + a persistent gp3 `/data` EBS volume (xfs).
- IAM (SSM core + ECR pull), a public 80/443 security group.
- `user_data` that mounts `/data`, writes `docker-compose.yml` + `Caddyfile`, and (optionally)
  `docker compose up`. Services: `atp-indexer` (port 42068), `local-postgres` (16), `caddy`.
- Optionally (prod) a CloudFront distribution fronting the indexer hostname with ACM
  (us-east-1), an http-only origin via a stable `atp-si-origin.<env>` A-record → EIP, and the
  CloudFront secret header that Caddy enforces.

## Deploy
```sh
cd atp-indexer/single-instance
terraform init -backend-config="key=<env>/staking-dashboard/atp-indexer-single-instance/terraform.tfstate"
terraform apply \
  -var env=testnet \
  -var si_atp_indexer_image=<account>.dkr.ecr.eu-west-2.amazonaws.com/staking-dashboard-testnet-atp-indexer:<tag> \
  -var si_atp_database_schema=atp_indexer \
  -var si_atp_indexer_domain=indexer.testnet.stake.aztec.network
```
Then SSM onto the box, populate `/opt/staking-dashboard-atp/env/atp-indexer.env` with the
same values the ECS task-def used (RPC_URL, CHAIN_ID, START_BLOCK, the `ATP_FACTORY_*` /
`*_START_BLOCK` / registry vars — see `atp-indexer/terraform/app.tf`), then
`docker compose up -d` (or set `-var si_start_services_on_boot=true` once the env file exists).

### testnet (Caddy-direct)
`-var si_create_dns_records=true` → Caddy gets Let's Encrypt certs for the hostname (point DNS
at the EIP first).

### prod (CloudFront-front)
`-var si_front_with_cloudfront=true -var si_create_dns_records=false`
`-var cloudfront_secret_header_value=<secret>` (Caddy enforces it; CloudFront injects it)
`-var si_cf_web_acl_arn=<cloudfront-scoped WAF arn>` (optional).
CloudFront serves viewer TLS; the box serves http-only to CloudFront only.

## Cutover (decommission the old fleet)
1. Stand up this box; seed/let it reach head (the indexer is RPC-bound — see ignition's
   ROAD-TO-PROD notes; restore a `pg_dump` if you have one to skip the reindex).
2. Repoint the **frontend's** indexer URL to this box's endpoint:
   - testnet: the hostname now resolves to the EIP (Caddy-direct), or
   - prod: `cloudfront_domain_name` output (or move the existing indexer hostname's alias here).
   The frontend reads the atp-indexer's URL from remote state today
   (`staking-dashboard/terraform` → `atp_indexer_url`); update that source at cutover.
3. After parity, tear down the old `atp-indexer/terraform` ECS service / Aurora / ALB
   (e.g. scale the service to 0, then `terraform destroy` those resources). **Snapshot the
   Aurora data first.** Keep the existing CloudFront if you prefer to repoint its origin
   instead of using this stack's CloudFront — either works; pick one to own the hostname.

## Notes
- Intentional duplication of the ignition single-instance templates (the repos are decoupled).
- `terraform validate` passes. Not yet applied; prod is a separate account — review + `plan`
  there before applying.

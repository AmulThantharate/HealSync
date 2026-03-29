"""
lambda/handler.py — HealSync health check + automated failover orchestrator.
Runs every 60 s via EventBridge. Triggers failover after 3 consecutive failures.
RTO target: 10 min | RPO target: 5 min
"""
import json
import logging
import os
import time
import urllib.request
import urllib.error
import boto3
from datetime import datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Lazy-init boto3 clients (reused across warm invocations)
_r53 = _rds = _ssm = _sns = _eks_client = None

def _clients():
    global _r53, _rds, _ssm, _sns, _eks_client
    region = os.environ["AWS_REGION_NAME"]
    if _r53 is None:
        _r53        = boto3.client("route53",    region_name=region)
        _rds        = boto3.client("rds",        region_name=region)
        _ssm        = boto3.client("ssm",        region_name=region)
        _sns        = boto3.client("sns",        region_name=region)
        _eks_client = boto3.client("eks",        region_name=region)


# ── Health probes ─────────────────────────────────────────────────────────────
def _http(url, timeout=5):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "HealSync-HealthCheck/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status < 500, f"HTTP {r.status}"
    except urllib.error.HTTPError as e:
        return e.code < 500, f"HTTP {e.code}"
    except Exception as e:
        return False, str(e)

def check_eks():
    _clients()
    try:
        r = _eks_client.describe_cluster(name=os.environ["EKS_CLUSTER"])
        s = r["cluster"]["status"]
        return {"healthy": s == "ACTIVE", "status": s}
    except Exception as e:
        return {"healthy": False, "status": str(e)}

def check_rds():
    _clients()
    try:
        r = _rds.describe_db_instances(DBInstanceIdentifier=os.environ["RDS_IDENTIFIER"])
        s = r["DBInstances"][0]["DBInstanceStatus"]
        return {"healthy": s == "available", "status": s}
    except Exception as e:
        return {"healthy": False, "status": str(e)}

def check_app():
    domain = os.environ.get("APP_DOMAIN", "")
    if not domain:
        return {"healthy": True, "status": "skipped"}
    ok, reason = _http(f"https://{domain}/health")
    return {"healthy": ok, "status": reason}


# ── SSM state helpers ─────────────────────────────────────────────────────────
def _env():
    return os.environ["ENVIRONMENT"]

def _ssm_get(key, default="0"):
    _clients()
    try:
        return _ssm.get_parameter(Name=f"/dr/{_env()}/{key}")["Parameter"]["Value"]
    except Exception:
        return default

def _ssm_put(key, value):
    _clients()
    _ssm.put_parameter(Name=f"/dr/{_env()}/{key}", Value=str(value),
                       Type="String", Overwrite=True)

def failover_active():
    return _ssm_get("failover-active", "false") == "true"

def mark_failover_active():
    _ssm_put("failover-active", "true")

def get_failures():
    return int(_ssm_get("consecutive-failures", "0"))

def set_failures(n):
    _ssm_put("consecutive-failures", str(n))


# ── Failover steps ────────────────────────────────────────────────────────────
def step_route53(log):
    """Update Route53 CNAME to the configured failover target."""
    _clients()
    try:
        _r53.change_resource_record_sets(
            HostedZoneId=os.environ["ROUTE53_ZONE_ID"],
            ChangeBatch={
                "Comment": f"HealSync failover {datetime.now(timezone.utc).isoformat()}",
                "Changes": [{
                    "Action": "UPSERT",
                    "ResourceRecordSet": {
                        "Name": os.environ["APP_DOMAIN"],
                        "Type": "CNAME",
                        "TTL":  30,
                        "ResourceRecords": [{"Value": os.environ["FAILOVER_CNAME_TARGET"]}]
                    }
                }]
            }
        )
        log.append({"step": "route53", "status": "ok"})
        logger.info("Route53 CNAME updated to failover target")
    except Exception as e:
        log.append({"step": "route53", "status": "error", "error": str(e)})
        raise

def step_record_aws_target(log):
    """Record intended AWS failover target for timeline visibility."""
    log.append({"step": "aws_target", "status": "ok", "target": os.environ.get("FAILOVER_CNAME_TARGET", "")})

def step_sns_alert(log, t0):
    """Publish full failover timeline to SNS → PagerDuty / Slack / email."""
    _clients()
    elapsed = round(time.time() - t0, 1)
    payload = {
        "event":       "DR_FAILOVER",
        "environment": _env(),
        "timestamp":   datetime.now(timezone.utc).isoformat(),
        "elapsed_s":   elapsed,
        "within_rto":  elapsed < 600,
        "steps":       log,
    }
    try:
        _sns.publish(
            TopicArn=os.environ["SNS_TOPIC_ARN"],
            Subject=f"[HealSync] Failover triggered — {_env()}",
            Message=json.dumps(payload, indent=2),
        )
        logger.info(f"SNS alert published. Elapsed: {elapsed}s")
    except Exception as e:
        logger.error(f"SNS failed: {e}")


# ── Failover orchestrator ──────────────────────────────────────────────────────
def trigger_failover():
    if failover_active():
        logger.info("Failover already active — skipping duplicate trigger")
        return {"status": "already_active"}

    mark_failover_active()
    t0  = time.time()
    log = []
    logger.info("=== HealSync FAILOVER INITIATED ===")

    # Ordered: DNS first (fastest), then record target, then alert
    step_route53(log)
    step_record_aws_target(log)
    step_sns_alert(log, t0)

    elapsed = round(time.time() - t0, 1)
    logger.info(f"=== FAILOVER COMPLETE {elapsed}s ===")
    return {"status": "failover_complete", "elapsed_s": elapsed,
            "within_rto": elapsed < 600, "steps": log}


# ── Entry point ───────────────────────────────────────────────────────────────
def lambda_handler(event, context):
    action = event.get("action", "health_check")

    if action == "failover":
        # Manual trigger via Function URL or CLI
        logger.info("Manual failover triggered")
        return trigger_failover()

    # Scheduled health check
    eks = check_eks()
    rds = check_rds()
    app = check_app()
    all_ok = eks["healthy"] and rds["healthy"] and app["healthy"]

    result = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "healthy":   all_ok,
        "checks":    {"eks": eks, "rds": rds, "app": app},
    }
    logger.info(json.dumps(result))

    if all_ok:
        set_failures(0)
        return result

    failures = get_failures() + 1
    set_failures(failures)
    logger.warning(f"Health check failed — consecutive failures: {failures}/3")

    if failures >= 3:
        logger.error("Failure threshold reached — triggering failover")
        result["failover"] = trigger_failover()

    return result

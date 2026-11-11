#!/usr/bin/env python3
"""Generate a mixed corpus of log lines for the LOG-10547 level-eval benchmark.

Categories model the stages of the VIAQ level-detection cascade:
  logfmt       - attempt 1 hit (level=... logfmt line)
  klog         - attempt 2 hit (k8s component logs)
  grok         - attempt 3 hit (classic "TIMESTAMP LEVEL message" text)
  json         - structured JSON without a level field (full fallback cascade)
  plain        - free text with no level signal (worst case: all attempts)
  keyword      - free text containing a level keyword (attempt 5 hit)
  oversized    - 50KB lines with no signal (fallback + allocation pressure)

Usage: gen_corpus.py --out corpus.log --total 20000 --mix klog=40,json=30,...
Ratios are percentages; unspecified categories default to 0. Lines are
shuffled so both implementations see identical, interleaved input.
"""
import argparse
import json
import random

CONTAINERS = ["api-server", "scheduler", "kube-proxy", "controller-manager",
              "etcd", " ingress-controller", "registry", "ovnkube-node",
              "csi-snapshot-controller", "cluster-policy-controller"]
COMPONENTS = ["scheduler.go", "apiserver.go", "controller.go", "round_trippers.go",
              "reflector.go", "validation.go", "handler.go", "klog.go"]
LOGGERS = ["kafka.consumer", "http.client", "pool.manager", "cache.evictor",
           "auth.provider", "queue.dispatch", "tls.handshake", "dns.resolver"]
LEVEL_WORDS = ["emergency", "alert", "critical", "error", "warn", "warning",
               "notice", "info", "debug", "trace"]
HOSTS = ["10.0.0.5", "10.1.2.3", "192.168.1.100", "api.backend.svc", "db-primary.svc"]


def gen_klog(i):
    sev = random.choice("IWEF")
    # valid MMDD so parse_klog's timestamp validation succeeds
    mmdd = f"{random.randint(1,12):02d}{random.randint(1,28):02d}"
    ts = f"{random.randint(10,23)}:{random.randint(10,59)}:{random.randint(10,59)}.{random.randint(100000,999999)}"
    return (f"{sev}{mmdd} {ts} {random.randint(1,99999)} "
            f"{random.choice(COMPONENTS)}:{random.randint(1,9999)}] "
            f"\"{random.choice(['Successfully bound pod to node', 'restarting container', 'syncing endpoints', 'watch closed', 'backoff retry'])} {i}\"")


def gen_json(i):
    # no level field, no level keywords anywhere in the payload
    msgs = ["failed to establish connection upstream",
            "retrying operation after backoff",
            "cache eviction completed for shard",
            "request completed with status 202",
            "pool resized to 8 workers"]
    return json.dumps({"ts": f"2026-11-09T10:{random.randint(10,59)}:{random.randint(10,59)}Z",
                       "logger": random.choice(LOGGERS),
                       "msg": f"{random.choice(msgs)} {i}",
                       "attempt": random.randint(1, 5)})


def gen_logfmt(i):
    lvl = random.choice(LEVEL_WORDS)
    return (f'level={lvl} ts=2026-11-09T10:00:{random.randint(10,59)}Z '
            f'logger={random.choice(LOGGERS)} msg="connection refused to {random.choice(HOSTS)}:{random.randint(1000,9999)} attempt {i}"')


def gen_grok(i):
    lvl = random.choice(["ERROR", "WARN", "INFO", "DEBUG", "TRACE", "Error",
                         "Warning", "CRITICAL", "Fatal", "Notice"])
    return (f"2026-11-09T10:{random.randint(10,59)}:{random.randint(10,59)}.{random.randint(100,999)}Z "
            f"{lvl} com.example.{random.choice(COMPONENTS).replace('.go','')} - "
            f"processing request {i} took {random.randint(1,999)}ms")


def gen_plain(i):
    return (f"2026-11-09 10:{random.randint(10,59)}:{random.randint(10,59)} "
            f"{random.choice(CONTAINERS).strip()}[{random.randint(100,99999)}]: "
            f"connection to {random.choice(HOSTS)}:{random.randint(1000,9999)} "
            f"timed out after {random.randint(1,30)}s on attempt {i}")


def gen_keyword(i):
    word = random.choice(["error", "warning", "notice", "debug", "trace", "critical", "alert"])
    return (f"2026-11-09 10:{random.randint(10,59)}:{random.randint(10,59)} "
            f"upstream {word} reported by {random.choice(CONTAINERS).strip()} "
            f"while draining queue {i}")


def gen_oversized(i):
    filler = "z" * 51200
    return f"2026-11-09 10:00:00 padding block {i} {filler}"


GENS = {"logfmt": gen_logfmt, "klog": gen_klog, "grok": gen_grok,
        "json": gen_json, "plain": gen_plain, "keyword": gen_keyword,
        "oversized": gen_oversized}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--out", required=True)
    p.add_argument("--total", type=int, default=20000)
    p.add_argument("--mix", default="klog=40,json=30,plain=15,keyword=10,logfmt=4,grok=1")
    p.add_argument("--seed", type=int, default=42)
    args = p.parse_args()

    random.seed(args.seed)
    mix = {}
    for part in args.mix.split(","):
        k, _, v = part.partition("=")
        mix[k] = float(v)
    total_pct = sum(mix.values())
    if abs(total_pct - 100.0) > 0.01:
        p.error(f"mix percentages sum to {total_pct}, expected 100")

    lines = []
    for cat, pct in mix.items():
        n = round(args.total * pct / 100.0)
        lines.extend(GENS[cat](i) for i in range(n))
    random.shuffle(lines)

    with open(args.out, "w") as f:
        f.write("\n".join(lines) + "\n")
    counts = {cat: round(args.total * pct / 100.0) for cat, pct in mix.items()}
    print(f"wrote {len(lines)} lines to {args.out}: {counts}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Measure two complete OS-host commands on identical recorded block source inputs."""
import argparse
from contextlib import suppress
import json
import os
import signal
from pathlib import Path
import platform
import random
import statistics
import subprocess
import tempfile
import threading
import time

import echonet_job
from qualify_os_host import asset, digest, require


def run_arm(command, archive, destination, scratch, expected, timeout):
    # No shell expansion. Both commands own input decompression, witness preparation and PIE publication.
    variables = {"{source}": str(archive), "{output}": str(destination), "{work}": str(scratch)}
    args = [variables.get(token, token) for token in command]
    scratch.mkdir()
    usage = scratch / "usage.txt"
    timer = "/usr/bin/time" if Path("/usr/bin/time").is_file() else "time"
    start = time.monotonic_ns()
    with subprocess.Popen([timer, "-f", "%M", "-o", str(usage), "--", *args],
                          cwd=scratch, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                          start_new_session=True) as proc:
        def interrupt():
            with suppress(ProcessLookupError):
                os.killpg(proc.pid, signal.SIGKILL)
        watchdog = threading.Timer(timeout, interrupt)
        watchdog.start()
        try:
            proc.wait()
            elapsed = time.monotonic_ns() - start
        finally:
            watchdog.cancel()
            watchdog.join()
            if proc.poll() is None:
                interrupt()
                proc.wait()
    require(proc.returncode == 0, f"job exited {proc.returncode}")
    require(digest(destination) == expected, "published PIE differs from authenticated reference")
    return {"wall_ns": elapsed, "max_rss_kib": int(usage.read_text().strip()), "pie_sha256": expected}


def measure(plan_file, rounds, seed, timeout, out):
    require(platform.system() == "Linux" and platform.machine() == "x86_64", "requires a dedicated x86_64 Linux host")
    require(rounds >= 2, "at least two paired rounds required")
    plan = json.loads(plan_file.read_bytes())
    require(plan["schema"] == 1 and plan["chain_id"] == "SN_MAIN", "expected a mainnet plan")
    root = plan_file.resolve().parent
    source_hash = plan["qualified_manifest_sha256"]
    qualification = json.loads(asset(root, plan["qualification"]).read_bytes())
    require(qualification["manifest_sha256"] == source_hash and qualification["chain_id"] == "SN_MAIN",
            "qualification does not cover plan manifest")
    qualified = {case["number"]: case for case in qualification["cases"]}
    cases = plan["cases"]
    require(cases and len(cases) == len(qualified) and {case["number"] for case in cases} == qualified.keys(),
            "whole jobs must cover every qualified case exactly once")
    arms = {"rust", "oxcairo"}
    staged = "pipeline" in plan
    require(staged != ("commands" in plan), "choose pipeline or external commands")
    if not staged:
        require(plan["commands"].keys() == arms, "expected two complete job commands")
    commands = {}
    identities = {}
    for arm, spec in plan.get("commands", {}).items():
        exe = asset(root, spec["executable"])
        argv = spec["arguments"]
        require(isinstance(argv, list) and all(isinstance(arg, str) for arg in argv)
                and {"{source}", "{output}", "{work}"} <= set(argv), "incomplete job arguments")
        commands[arm] = [str(exe), *argv]
        identities[arm] = spec["executable"]["sha256"]
    require(isinstance(plan["cache_policy"], str) and plan["cache_policy"].strip(), "missing cache policy")
    require(isinstance(plan["hardware"], str) and plan["hardware"].strip(), "missing hardware description")
    rng = random.Random(seed)
    rows = []
    inputs = {case["number"]: asset(root, case["source"]) for case in cases}
    witnesses = {}
    for case in cases:
        if staged:
            number = case["number"]
            require(case["witness"]["sha256"] == qualified[number]["witness_sha256"],
                    "witness reference differs from qualification")
            witnesses[number] = echonet_job.canonical_witness_hash(asset(root, case["witness"]))
        require(case["source"]["sha256"] == qualified[case["number"]]["source_sha256"],
                "raw source differs from the qualified block")
    profile = "external-commands"
    with tempfile.TemporaryDirectory(dir=out.parent) as work:
        temp = Path(work).resolve()
        if staged:
            commands = echonet_job.commands(root, plan, qualification, temp)
            pipeline = plan["pipeline"]
            profile = "echonet-installed-host-v1" if "host" in pipeline else "echonet-direct-cli"
            identities = {arm: pipeline[arm]["sha256"] for arm in arms}
            if "host" in pipeline:
                identities["host"] = pipeline["host"]["sha256"]
        for rnd in range(rounds):
            numbers = list(inputs)
            rng.shuffle(numbers)
            for number in numbers:
                order = ["rust", "oxcairo"]
                rng.shuffle(order)
                for arm in order:
                    with tempfile.TemporaryDirectory(dir=temp) as run:
                        directory = Path(run)
                        command = commands[arm]
                        case = qualified[number]
                        if staged:
                            command = [*command, case["source_sha256"], witnesses[number], case["sha256"]]
                        sample = run_arm(command, inputs[number], directory / "block.zip",
                                         directory / "work", qualified[number]["sha256"], timeout)
                        if staged:
                            sample["canonical_witness_sha256"] = witnesses[number]
                            sample["stage_ns"] = json.loads((directory / "work/stages.json").read_bytes())
                    rows.append(dict(round=rnd, number=number, arm=arm, **sample))
    totals = {arm: 0 for arm in arms}
    cases_summary = []
    for number in inputs:
        times = {arm: statistics.median(r["wall_ns"] for r in rows if r["number"] == number and r["arm"] == arm)
                 for arm in arms}
        for arm in arms:
            totals[arm] += times[arm]
        cases_summary.append(dict(number=number, median_wall_ns=times, speedup=times["rust"]/times["oxcairo"]))
    return dict(schema=1, execution_profile=profile, hardware=plan["hardware"], kernel=platform.release(), cache_policy=plan["cache_policy"],
                plan_sha256=digest(plan_file), qualified_manifest_sha256=source_hash, executable_sha256=identities,
                rounds=rounds, seed=seed, cases=cases_summary, rows=rows,
                median_speedup=statistics.median(v["speedup"] for v in cases_summary),
                summed_speedup=totals["rust"]/totals["oxcairo"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plan", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args()
    if args.output.exists():
        parser.error("choose a fresh output path")
    result = measure(args.plan, args.rounds, args.seed, args.timeout, args.output)
    with args.output.open("x") as stream:
        json.dump(result, stream, indent=2)


if __name__ == "__main__":
    main()

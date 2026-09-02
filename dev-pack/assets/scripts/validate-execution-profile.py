#!/usr/bin/env python3
"""Fail closed unless a semantic execution role set is explicitly city-bound."""
import argparse
import json
import sys
import tomllib
from pathlib import Path


def fail(message: str) -> None:
    print(f"execution profile validation: {message}", file=sys.stderr)
    raise SystemExit(2)


parser = argparse.ArgumentParser(add_help=False)
parser.add_argument("--city", required=True)
parser.add_argument("--policy", required=True)
parser.add_argument("--rig", required=True)
parser.add_argument("--profile", required=True)
args = parser.parse_args()

city_path = Path(args.city)
city_file = city_path if city_path.is_file() else city_path / "city.toml"
try:
    city = tomllib.loads(city_file.read_text())
except (OSError, tomllib.TOMLDecodeError) as exc:
    fail(f"cannot read {city_file}: {exc}")
try:
    policy = json.loads(Path(args.policy).read_text())
    profile = policy["execution_profiles"][args.profile]
except KeyError:
    names = ", ".join(sorted(policy.get("execution_profiles", {})))
    fail(f"unknown profile '{args.profile}' (available: {names})")
except (OSError, json.JSONDecodeError) as exc:
    fail(f"cannot read policy: {exc}")

rig = next((item for item in city.get("rigs", []) if item.get("name") == args.rig), None)
if rig is None:
    fail(f"rig '{args.rig}' is not configured in {city_file}")

targets = []
for roles in profile.get("roles", {}).values():
    targets.extend(roles.values())
targets = sorted(set(targets))
if not targets:
    fail(f"profile '{args.profile}' has no role targets")

expected_effort = profile.get("reasoning_effort")
if expected_effort not in {"medium", "high", "xhigh"}:
    fail(f"profile '{args.profile}' has no valid reasoning_effort contract")
if not args.profile.endswith(f"-{expected_effort}"):
    fail(f"profile '{args.profile}' contradicts reasoning_effort '{expected_effort}'")

patches = {patch.get("agent"): patch for patch in rig.get("patches", [])}
providers = city.get("providers", {})
for target in targets:
    patch = patches.get(target)
    if patch is None:
        fail(f"{args.rig}/{target} has no explicit [[rigs.patches]] binding")
    provider = patch.get("provider")
    options = patch.get("option_defaults", {})
    if not provider or not options.get("model") or not options.get("effort"):
        fail(f"{args.rig}/{target} must explicitly bind provider, model, and effort")
    if provider not in providers:
        fail(f"{args.rig}/{target} binds unconfigured provider '{provider}'")
    if options["effort"] != expected_effort:
        fail(
            f"{args.rig}/{target} binds effort '{options['effort']}', "
            f"but profile '{args.profile}' requires '{expected_effort}'"
        )

print(json.dumps({"profile": args.profile, "rig": args.rig, "targets": targets}, separators=(",", ":")))
